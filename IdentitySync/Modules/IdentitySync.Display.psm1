<#
.SYNOPSIS
    Terminal output for the HRIS to Entra ID identity sync.

.DESCRIPTION
    Everything the sync prints to the terminal lives here, so the decision
    rules in IdentitySync.psm1 stay free of output and the entry script stays
    a short list of steps.

    Public functions:
      Write-RunHeader          Prints the run banner and what was read.
      Write-Decision           Prints one decision: action, reason, a table of
                               the HRIS record next to the Entra account, and
                               any attribute changes.
      Write-UnmatchedIdentity  Lists Entra identities with no HRIS record.
      Write-PlanSummary        Prints how many workers got each action.
      Write-SectionHeading     Prints a section heading.
      Write-WorkerOutcome      Prints what was done for one worker, under their decision.
      Write-StageSummary       Prints how many workers are at each stage.
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

# Colour for each pipeline stage, and for the Update and Disable change results.
# Green = finished, yellow = waiting or retrying, red = stopped for a person.
$script:StageColours = @{
    Pending         = 'DarkGray'
    IdentityReady   = 'Yellow'
    IdentityFailed  = 'Yellow'
    MailboxPending  = 'Yellow'
    MailboxReady    = 'Yellow'
    WriteBackFailed = 'Yellow'
    Complete        = 'Green'
    ManualReview    = 'Red'
    MailboxTimeout  = 'Red'
    Update          = 'Cyan'
    Disable         = 'Yellow'
}

# The stages in the order the stage summary lists them.
$script:StageOrder = @('Complete', 'Pending', 'IdentityReady', 'IdentityFailed', 'MailboxPending',
                       'MailboxReady', 'WriteBackFailed', 'ManualReview', 'MailboxTimeout')

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
        Prints the run banner (dry run or applying changes) and how much was read.
    #>
    [CmdletBinding()]
    param(
        [int] $WorkerCount,
        [datetime] $Today,
        [switch] $Apply
    )

    Write-Host ''
    if ($Apply) {
        Write-Host 'APPLYING CHANGES: Entra ID, Exchange Online and the HRIS will be updated.' -ForegroundColor Magenta
        Write-Host 'Each worker below shows the decision, the data behind it, what was done, and the result.' -ForegroundColor DarkGray
    }
    else {
        Write-Host 'DRY RUN: decisions only, nothing is changed. Add -Apply to make the changes.' -ForegroundColor Yellow
        Write-Host 'Each worker below shows the decision and the data behind it.' -ForegroundColor DarkGray
    }
    Write-Host 'In each table, values that differ between the HRIS and Entra are in magenta.' -ForegroundColor DarkGray
    Write-Host ('Read {0} HRIS records. Today is {1}.' -f $WorkerCount, $Today.ToString('yyyy-MM-dd')) -ForegroundColor DarkGray
}

function Write-Decision {
    <#
    .SYNOPSIS
        Prints one decision.
    .DESCRIPTION
        Prints a dividing line, then the action, employeeId and name (with the
        worker's position in the run), the reason, a table of the HRIS record
        next to the Entra account, and for an Update or Disable each attribute
        that would change. For example:

          ------------------------------------------------------------------
          Update        E9003      Quinn Roberts  (8 of 23)
                        Changed attributes: department, managerEmployeeId
                        Field       HRIS                    Entra
                        ...
                        Planned     department: Operations -> Finance
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Decision,
        [int] $Number,
        [int] $Total
    )

    $colour = $script:ActionColours[$Decision.Action]
    $id     = if ($Decision.EmployeeId) { $Decision.EmployeeId } else { '(missing)' }

    Write-Host ''
    Write-Host ('-' * 78) -ForegroundColor DarkGray
    Write-Host ('{0,-14}' -f $Decision.Action) -ForegroundColor $colour -NoNewline
    Write-Host ('{0,-11}' -f $id) -ForegroundColor Cyan -NoNewline
    Write-Host $Decision.Name -ForegroundColor White -NoNewline
    if ($Total -gt 0) { Write-Host ("  ($Number of $Total)") -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
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
            Write-Host ('{0,-14}{1,-12}' -f '', 'Planned') -ForegroundColor DarkGray -NoNewline
            Write-Host ('{0}: {1} -> {2}' -f $attribute, $from, $to) -ForegroundColor $colour
        }
    }
}

function Write-WorkerOutcome {
    <#
    .SYNOPSIS
        Prints what happened for one worker in a run with -Apply.
    .DESCRIPTION
        Prints one Result line for the change to an existing identity (Update
        or Disable) and one for the identity, mailbox and write-back stages,
        under the worker's decision. For a worker with neither, for example a
        ManualReview, it says nothing was done. For example:

                        Result      Complete        Updated: Wrote alex.clarke@example.com to the HRIS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Decision,
        $Change,
        $Stages
    )

    $results = @($Change, $Stages | Where-Object { $null -ne $_ })
    if ($results.Count -eq 0) {
        Write-Host ('{0,-14}{1,-12}' -f '', 'Result') -ForegroundColor DarkGray -NoNewline
        Write-Host "Nothing done ($($Decision.Action))" -ForegroundColor $script:ActionColours[$Decision.Action]
        return
    }

    foreach ($result in $results) {
        $colour = $script:StageColours[$result.Stage]
        if (-not $colour) { $colour = 'White' }
        if ($result.Outcome -in 'Failed', 'Skipped' -and $result.Stage -in 'Update', 'Disable') { $colour = 'Red' }

        Write-Host ('{0,-14}{1,-12}' -f '', 'Result') -ForegroundColor DarkGray -NoNewline
        Write-Host ('{0,-16}' -f $result.Stage) -ForegroundColor $colour -NoNewline
        Write-Host ('{0}: {1}' -f $result.Outcome, $result.Reason) -ForegroundColor DarkGray
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

function Write-SectionHeading {
    <#
    .SYNOPSIS
        Prints a section heading, such as 'Changes to existing identities'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)

    Write-Host ''
    Write-Host $Text -ForegroundColor White
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Write-StageSummary {
    <#
    .SYNOPSIS
        Prints how many workers are at each stage, from the sync state.
    .DESCRIPTION
        Used at the end of a run with -Apply, and on a dry run to show what a
        previous run left in progress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [string] $Title = 'Workers by stage (from the sync state):'
    )

    $entries = @($State.workers.Values)
    Write-Host ''
    if ($entries.Count -eq 0) {
        Write-Host 'The sync state is empty: no run has applied changes yet.' -ForegroundColor DarkGray
        return
    }

    Write-Host $Title -ForegroundColor Green
    foreach ($stage in $script:StageOrder) {
        $atStage = @($entries | Where-Object { $_.stage -eq $stage } | Sort-Object employeeId)
        if ($atStage.Count -eq 0) { continue }
        Write-Host ('  {0,-17}{1,-4}' -f $stage, $atStage.Count) -ForegroundColor $script:StageColours[$stage] -NoNewline
        Write-Host (@($atStage.employeeId) -join ', ') -ForegroundColor DarkGray
    }
}
#endregion

Export-ModuleMember -Function Write-RunHeader, Write-Decision, Write-UnmatchedIdentity, Write-PlanSummary,
    Write-SectionHeading, Write-WorkerOutcome, Write-StageSummary
