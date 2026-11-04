<#
.SYNOPSIS
    Terminal output for the HRIS to Entra ID identity sync.

.DESCRIPTION
    Everything the sync prints to the terminal lives here, so the decision
    rules in IdentitySync.psm1 stay free of output and the entry script stays
    a short list of steps.

    Public functions:
      Write-RunHeader          Prints the dry-run banner and what was read.
      Write-Decision           Prints one decision: action, reason, a table of
                               the HRIS record next to the Entra account, and
                               any attribute changes.
      Write-UnmatchedIdentity  Lists Entra identities with no HRIS record.
      Write-PlanSummary        Prints how many workers got each action.
#>

Set-StrictMode -Version Latest

#region Settings
# Colour for each action in the terminal.
$script:ActionColours = @{
    Create       = 'Green'
    Update       = 'Cyan'
    Disable      = 'Yellow'
    NoChange     = 'DarkGray'
    ManualReview = 'Red'
}

# The actions in the order the summary lists them.
$script:ActionOrder = @('Create', 'Update', 'Disable', 'NoChange', 'ManualReview')

# Rows of the HRIS vs Entra table: the label, the HRIS field and the Entra
# attribute shown in that row ($null where one side has no such field).
# Across = compare the HRIS value with the Entra value. Rows without it are
# only compared between records on the same side, for example two HRIS
# records that share an employeeId. Note = text shown after the row when its
# values differ, to explain why the difference does not cause an Update.
$script:ComparisonRows = @(
    @{ Label = 'Employee ID'; HRIS = 'employeeId';        Entra = 'employeeId';        Across = $true }
    @{ Label = 'First name';  HRIS = 'firstName';         Entra = 'givenName';         Across = $true; Note = '(not synced)' }
    @{ Label = 'Last name';   HRIS = 'lastName';          Entra = 'surname';           Across = $true; Note = '(not synced)' }
    @{ Label = 'Status';      HRIS = 'status';            Entra = $null }
    @{ Label = 'Account';     HRIS = $null;               Entra = 'accountEnabled' }
    @{ Label = 'Department';  HRIS = 'department';        Entra = 'department';        Across = $true }
    @{ Label = 'Manager';     HRIS = 'managerEmployeeId'; Entra = 'managerEmployeeId'; Across = $true }
    @{ Label = 'Start date';  HRIS = 'startDate';         Entra = $null }
    @{ Label = 'End date';    HRIS = 'endDate';           Entra = $null }
    @{ Label = 'Email';       HRIS = 'email';             Entra = 'mail';              Across = $true; Note = '(handled by email write-back)' }
    @{ Label = 'Object ID';   HRIS = $null;               Entra = 'id' }
)
#endregion

#region Private helpers
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
    $HRISRecords = @($Decision.HRISRecords)
    $entraIds    = @($Decision.EntraIdentities)

    $columns = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $HRISRecords.Count; $i++) {
        $header = if ($HRISRecords.Count -gt 1) { "HRIS #$($i + 1)" } else { 'HRIS' }
        $columns.Add([pscustomobject]@{ Header = $header; Side = 'HRIS'; Record = $HRISRecords[$i] })
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
    $table = foreach ($row in $script:ComparisonRows) {
        $cells = foreach ($column in $columns) {
            $field = if ($column.Side -eq 'HRIS') { $row.HRIS } else { $row.Entra }
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
#endregion

#region Public functions
function Write-RunHeader {
    <#
    .SYNOPSIS
        Prints the dry-run banner and how much was read.
    #>
    [CmdletBinding()]
    param(
        [int] $WorkerCount,
        [int] $IdentityCount,
        [datetime] $Today
    )

    Write-Host ''
    Write-Host 'DRY RUN: decisions only, nothing is changed.' -ForegroundColor Yellow
    Write-Host 'Each decision shows the HRIS record next to the Entra account. Values that differ are in magenta.' -ForegroundColor DarkGray
    Write-Host ('Read {0} HRIS records and {1} Entra identities. Today is {2}.' -f
        $WorkerCount, $IdentityCount, $Today.ToString('yyyy-MM-dd')) -ForegroundColor DarkGray
}

function Write-Decision {
    <#
    .SYNOPSIS
        Prints one decision.
    .DESCRIPTION
        Prints the action, employeeId and name, the reason, a table of the
        HRIS record next to the Entra account, and for an Update or Disable
        each attribute that would change. For example:

          Update        E9003      Quinn Roberts
                        Changed attributes: department, managerEmployeeId
                        Field       HRIS                    Entra
                        ...
                          department: Operations -> Finance
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Decision)

    $colour = $script:ActionColours[$Decision.Action]
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

function Write-UnmatchedIdentity {
    <#
    .SYNOPSIS
        Lists Entra identities that have no HRIS record.
    .DESCRIPTION
        These are reported so someone can follow up, but never disabled
        automatically. Prints nothing when there are none.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Identities = @())

    if ($Identities.Count -eq 0) { return }

    Write-Host ''
    Write-Host ('{0} Entra identities have no HRIS record and are left unchanged:' -f $Identities.Count) -ForegroundColor Yellow
    foreach ($identity in $Identities) {
        Write-Host ('  {0,-11}{1} {2}' -f $identity.employeeId, $identity.givenName, $identity.surname) -ForegroundColor DarkGray
    }
}

function Write-PlanSummary {
    <#
    .SYNOPSIS
        Prints how many workers got each action.
    .DESCRIPTION
        One line per action, in a fixed order, including actions with no workers.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Decisions = @(),
        [int] $RecordCount
    )

    Write-Host ''
    Write-Host ('Decided {0} employeeIds from {1} records:' -f $Decisions.Count, $RecordCount) -ForegroundColor Green
    foreach ($action in $script:ActionOrder) {
        $count = @($Decisions | Where-Object { $_.Action -eq $action }).Count
        Write-Host ('  {0,-14}{1}' -f $action, $count) -ForegroundColor $script:ActionColours[$action]
    }
}
#endregion

Export-ModuleMember -Function Write-RunHeader, Write-Decision, Write-UnmatchedIdentity, Write-PlanSummary
