<#
.SYNOPSIS
    Decides the Entra ID identity action for every worker in an HRIS export.

.DESCRIPTION
    The entry point for the identity sync. It reads the HRIS workers file and
    the current Entra identities, then works out what should happen to each
    worker: Create, Update, Disable, NoChange or ManualReview.

    What the script does, in order:
      1. Reads the HRIS workers JSON and the Entra identities JSON.
      2. Validates every record and decides an action for each employeeId,
         using the rules in Modules\IdentitySync.psm1.
      3. Prints each decision with its reason, a side-by-side table of the
         worker's HRIS record and their Entra account (with differences
         highlighted, so you can see why the decision was made), and any
         attribute changes.
      4. Lists Entra identities that have no HRIS record. These are reported
         only: a worker missing from one file is never disabled.
      5. Prints a summary of how many workers got each action.

    This version is a dry run only: it decides but changes nothing. Applying
    decisions against the Entra ID, Exchange Online and HRIS mocks is added
    in a later step.

.PARAMETER WorkersPath
    The HRIS workers JSON file. Defaults to the mock in
    IdentitySync\Mocks\hris-workers.json.

.PARAMETER IdentitiesPath
    The Entra identities JSON file. Defaults to the mock in
    IdentitySync\Mocks\entra-identities.json.

.PARAMETER Today
    The date the rules treat as today. Defaults to the current date.

.EXAMPLE
    .\Invoke-IdentitySync.ps1
    Shows the decision for every worker in the default files.
#>
[CmdletBinding()]
param(
    [string] $WorkersPath = (Join-Path $PSScriptRoot '..\Mocks\hris-workers.json'),

    [string] $IdentitiesPath = (Join-Path $PSScriptRoot '..\Mocks\entra-identities.json'),

    [datetime] $Today = (Get-Date).Date
)

# Fail fast: treat undefined variables and any error as a stop.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\Modules\IdentitySync.psm1') -Force

#region Settings
# Colour for each action in the terminal.
$actionColours = @{
    Create       = 'Green'
    Update       = 'Cyan'
    Disable      = 'Yellow'
    NoChange     = 'DarkGray'
    ManualReview = 'Red'
}

# Rows of the HRIS vs Entra table: the label, the HRIS field and the Entra
# attribute shown in that row ($null where one side has no such field).
# Across = compare the HRIS value with the Entra value. Rows without it are
# only compared between records on the same side, for example two HRIS
# records that share an employeeId. Note = text shown after the row when its
# values differ, to explain why the difference does not cause an Update.
$comparisonRows = @(
    @{ Label = 'Employee ID'; Hris = 'employeeId';        Entra = 'employeeId';        Across = $true }
    @{ Label = 'First name';  Hris = 'firstName';         Entra = 'givenName';         Across = $true; Note = '(not synced)' }
    @{ Label = 'Last name';   Hris = 'lastName';          Entra = 'surname';           Across = $true; Note = '(not synced)' }
    @{ Label = 'Status';      Hris = 'status';            Entra = $null }
    @{ Label = 'Account';     Hris = $null;               Entra = 'accountEnabled' }
    @{ Label = 'Department';  Hris = 'department';        Entra = 'department';        Across = $true }
    @{ Label = 'Manager';     Hris = 'managerEmployeeId'; Entra = 'managerEmployeeId'; Across = $true }
    @{ Label = 'Start date';  Hris = 'startDate';         Entra = $null }
    @{ Label = 'End date';    Hris = 'endDate';           Entra = $null }
    @{ Label = 'Email';       Hris = 'email';             Entra = 'mail';              Across = $true; Note = '(handled by email write-back)' }
    @{ Label = 'Object ID';   Hris = $null;               Entra = 'id' }
)
#endregion

#region Helpers
# Reads a JSON array file and returns one item per element. Windows PowerShell
# 5.1 returns a JSON array as a single object, so it is stored first and then
# wrapped in @() to give the same result on every PowerShell version.
function Read-JsonArray {
    param([string] $Path, [string] $Description)

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -Path $fullPath -PathType Leaf)) {
        throw "$Description file not found: $fullPath"
    }

    try {
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($fullPath))
    }
    catch {
        throw "$Description file is not valid JSON: $fullPath. $($_.Exception.Message)"
    }
    return , @($parsed)
}

# Returns the text shown in one table cell:
#   $null       the column's side has no such field, so the cell is left blank
#   (missing)   the record does not have the field at all
#   -           the field is present but empty
#   Enabled / Disabled for true / false, otherwise the value itself
function Get-CellText {
    param($Record, [string] $Field)

    if (-not $Field -or ($null -eq $Record)) { return $null }

    $property = $Record.PSObject.Properties[$Field]
    if (-not $property) { return '(missing)' }

    $value = $property.Value
    if (($null -eq $value) -or ([string] $value -eq '')) { return '-' }
    if ($value -is [bool]) { return $(if ($value) { 'Enabled' } else { 'Disabled' }) }
    return [string] $value
}

# Prints the HRIS record(s) and Entra account(s) behind a decision side by
# side, one row per field, for example:
#
#                 Field       HRIS                    Entra
#                 Department  Finance                 Operations
#                 Manager     E1003                   E1002
#
# There is one column per HRIS record and per Entra account, so duplicate
# records and ambiguous matches show every candidate. Values that differ are
# highlighted in magenta.
function Write-ComparisonTable {
    param($Decision)

    # Build the columns: every HRIS record, then every Entra account.
    $hrisRecords = @($Decision.HrisRecords)
    $entraIds    = @($Decision.EntraIdentities)

    $columns = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $hrisRecords.Count; $i++) {
        $header = if ($hrisRecords.Count -gt 1) { "HRIS #$($i + 1)" } else { 'HRIS' }
        $columns.Add([pscustomobject]@{ Header = $header; Side = 'Hris'; Record = $hrisRecords[$i] })
    }
    if ($entraIds.Count -eq 0) {
        $columns.Add([pscustomobject]@{ Header = 'Entra (no account)'; Side = 'Entra'; Record = $null })
    }
    for ($i = 0; $i -lt $entraIds.Count; $i++) {
        $header = if ($entraIds.Count -gt 1) { "Entra #$($i + 1)" } else { 'Entra' }
        $columns.Add([pscustomobject]@{ Header = $header; Side = 'Entra'; Record = $entraIds[$i] })
    }

    # Work out the text for every cell first, one array of cells per row, so
    # each column can be made as wide as its longest value.
    $table = foreach ($row in $comparisonRows) {
        $cells = foreach ($column in $columns) {
            $field = if ($column.Side -eq 'Hris') { $row.Hris } else { $row.Entra }
            , (Get-CellText -Record $column.Record -Field $field)
        }
        [pscustomobject]@{ Row = $row; Cells = @($cells) }
    }

    # Each column is two characters wider than its longest value or header.
    $widths = for ($c = 0; $c -lt $columns.Count; $c++) {
        $longest = $columns[$c].Header.Length
        foreach ($line in $table) {
            $text = $line.Cells[$c]
            if ($text -and $text.Length -gt $longest) { $longest = $text.Length }
        }
        $longest + 2
    }
    $widths = @($widths)

    $indent = ' ' * 14

    # Header line.
    Write-Host ('{0}{1,-12}' -f $indent, 'Field') -ForegroundColor DarkGray -NoNewline
    for ($c = 0; $c -lt $columns.Count; $c++) {
        Write-Host $columns[$c].Header.PadRight($widths[$c]) -ForegroundColor DarkGray -NoNewline
    }
    Write-Host ''

    foreach ($line in $table) {
        $row   = $line.Row
        $cells = $line.Cells

        # Skip rows with nothing to show, such as Object ID when there is no account.
        $filled = @($cells | Where-Object { $null -ne $_ })
        if ($filled.Count -eq 0) { continue }

        # A row differs when its filled cells do not all hold the same value.
        # Rows that are not compared across sides only ever have cells from one
        # side filled, so this compares HRIS with HRIS or Entra with Entra.
        # Select-Object -Unique is case-sensitive, so 'alex' and 'Alex' differ.
        $differs = @($filled | Select-Object -Unique).Count -gt 1

        Write-Host ('{0}{1,-12}' -f $indent, $row.Label) -ForegroundColor DarkGray -NoNewline
        for ($c = 0; $c -lt $cells.Count; $c++) {
            $text = $cells[$c]
            if ($null -eq $text) {
                Write-Host (' ' * $widths[$c]) -NoNewline
                continue
            }

            $cellColour = if ($text -eq '(missing)') { 'Red' }
                          elseif ($text -eq '-')     { 'DarkGray' }
                          elseif ($differs)          { 'Magenta' }
                          else                       { 'White' }
            Write-Host $text.PadRight($widths[$c]) -ForegroundColor $cellColour -NoNewline
        }

        # Names and email can differ without causing an Update, so say why on the row.
        if ($differs -and $row.ContainsKey('Note')) {
            Write-Host $row.Note -ForegroundColor DarkGray -NoNewline
        }
        Write-Host ''
    }
}

# Prints one decision, for example:
#
#   Update        E9003      Quinn Roberts
#                 Changed attributes: department, managerEmployeeId
#                 Field       HRIS                    Entra
#                 ...
#                   department: Operations -> Finance
function Write-Decision {
    param($Decision)

    $colour = $actionColours[$Decision.Action]
    $id     = if ($Decision.EmployeeId) { $Decision.EmployeeId } else { '(missing)' }

    Write-Host ''
    Write-Host ('{0,-14}' -f $Decision.Action) -ForegroundColor $colour -NoNewline
    Write-Host ('{0,-11}' -f $id) -ForegroundColor Cyan -NoNewline
    Write-Host $Decision.Name -ForegroundColor White
    Write-Host ('{0,-14}{1}' -f '', $Decision.Reason) -ForegroundColor DarkGray

    # The data the decision was based on.
    Write-ComparisonTable -Decision $Decision

    # Updates and Disables list each attribute that would change. A Create
    # sets every attribute, so listing them adds nothing.
    if ($Decision.Action -in 'Update', 'Disable') {
        foreach ($attribute in $Decision.Changes.Keys) {
            $change = $Decision.Changes[$attribute]
            $from   = if ($null -eq $change.From) { '-' } else { $change.From }
            $to     = if ($null -eq $change.To)   { '-' } else { $change.To }
            Write-Host ('{0,-16}{1}: {2} -> {3}' -f '', $attribute, $from, $to) -ForegroundColor $colour
        }
    }
}
#endregion

#region Read inputs
$workers    = Read-JsonArray -Path $WorkersPath -Description 'Workers'
$identities = Read-JsonArray -Path $IdentitiesPath -Description 'Identities'

Write-Host ''
Write-Host 'DRY RUN: decisions only, nothing is changed.' -ForegroundColor Yellow
Write-Host 'Each decision shows the HRIS record next to the Entra account. Values that differ are in magenta.' -ForegroundColor DarkGray
Write-Host ('Read {0} HRIS records and {1} Entra identities. Today is {2}.' -f
    $workers.Count, $identities.Count, $Today.ToString('yyyy-MM-dd')) -ForegroundColor DarkGray
#endregion

#region Decide
$decisions = @(Get-IdentityPlan -Workers $workers -Identities $identities -Today $Today)

foreach ($decision in $decisions) {
    Write-Decision -Decision $decision
}
#endregion

#region Identities with no HRIS record
# Reported so someone can follow up, but never disabled automatically.
$unmatched = @(Get-UnmatchedIdentity -Workers $workers -Identities $identities)
if ($unmatched.Count -gt 0) {
    Write-Host ''
    Write-Host ('{0} Entra identities have no HRIS record and are left unchanged:' -f $unmatched.Count) -ForegroundColor Yellow
    foreach ($identity in $unmatched) {
        Write-Host ('  {0,-11}{1} {2}' -f $identity.employeeId, $identity.givenName, $identity.surname) -ForegroundColor DarkGray
    }
}
#endregion

#region Summary
# One line per action, in a fixed order, including actions with no workers.
Write-Host ''
Write-Host ('Decided {0} employeeIds from {1} records:' -f $decisions.Count, $workers.Count) -ForegroundColor Green
foreach ($action in 'Create', 'Update', 'Disable', 'NoChange', 'ManualReview') {
    $count = @($decisions | Where-Object { $_.Action -eq $action }).Count
    Write-Host ('  {0,-14}{1}' -f $action, $count) -ForegroundColor $actionColours[$action]
}
#endregion
