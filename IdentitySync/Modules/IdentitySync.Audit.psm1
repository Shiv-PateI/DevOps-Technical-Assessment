<#
.SYNOPSIS
    Structured audit log for the identity sync: one JSON line per event.

.DESCRIPTION
    Every run writes a new audit file in JSON Lines format (one JSON object
    per line), so it can be read by people, searched with Select-String, and
    loaded into a log tool such as Azure Log Analytics. Lines are appended as
    the run goes, so a run that stops part-way still leaves a record of what
    it did.

    Every line carries the run's correlation ID, a new GUID per run, so all
    the lines of one run can be found together. Each line has an "event":

      RunStarted          The run began: mode (DryRun or Apply) and how many
                          HRIS records were read.
      Worker              One line per employeeId: the proposed action and
                          reason, what was done (the change to an existing
                          identity and the identity, mailbox and write-back
                          stages), the Entra object ID, the confirmed primary
                          SMTP address, the write-back result, and how many
                          times calls were retried.
      IdentityNotInHRIS   An Entra identity with no HRIS record, left unchanged.
      RunCompleted        The run finished, with a count of each action and
                          each final stage.
      RunFailed           The run stopped with an error, and why.

    What is never written: passwords, API tokens, or whole HRIS records. A
    worker line holds the employeeId and Entra object ID but not the name,
    department or dates, to keep personal data in the log to what an audit
    needs.

    Public functions:
      New-AuditLog             Starts a new audit file for a run.
      ConvertTo-AuditEntry     Builds the Worker line for one decision.
      Write-AuditEntry         Appends one line to the audit file.
      Write-AuditRunStarted    Appends the RunStarted line.
      Write-AuditRunCompleted  Appends the RunCompleted line.
      Write-AuditRunFailed     Appends a RunFailed line when a run stops with an error.
      Write-AuditUnmatched     Appends one IdentityNotInHRIS line per identity.
#>

Set-StrictMode -Version Latest

#region Private helpers
# Returns a property from an object, or $null when it is missing.
function Get-AuditValue {
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# The fields every line starts with, in this order.
function New-AuditLine {
    param($Log, [string] $EventName)
    [ordered]@{
        timestamp     = [datetime]::UtcNow.ToString('o')
        correlationId = $Log.CorrelationId
        event         = $EventName
        mode          = $Log.Mode
    }
}
#endregion

#region Public functions
function New-AuditLog {
    <#
    .SYNOPSIS
        Starts a new audit file for one run and returns the log to write to.
    .DESCRIPTION
        The file is named audit-<UTC time>-<start of the correlation ID>.jsonl,
        so files sort by time and each run's file can be found from its
        correlation ID. The folder is created if missing.
    .PARAMETER Folder
        Where to create the file, such as IdentitySync\Reports.
    .PARAMETER DryRun
        Marks every line of this run as a dry run.
    .PARAMETER CorrelationId
        The run's ID. A new GUID is used if none is given.
    .OUTPUTS
        An object with Path, CorrelationId and Mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [switch] $DryRun,
        [string] $CorrelationId = ([guid]::NewGuid().ToString())
    )

    $fullFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Folder)
    if (-not (Test-Path -Path $fullFolder)) {
        New-Item -ItemType Directory -Path $fullFolder | Out-Null
    }

    $fileName = 'audit-{0}-{1}.jsonl' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), $CorrelationId.Substring(0, 8)
    [pscustomobject]@{
        Path          = Join-Path $fullFolder $fileName
        CorrelationId = $CorrelationId
        Mode          = if ($DryRun) { 'DryRun' } else { 'Apply' }
    }
}

function ConvertTo-AuditEntry {
    <#
    .SYNOPSIS
        Builds the audit line for one worker's decision and what was done.
    .PARAMETER Log
        From New-AuditLog.
    .PARAMETER Decision
        The worker's decision from Get-IdentityPlan.
    .PARAMETER Change
        The result of an Update or Disable, if there was one.
    .PARAMETER Stages
        The result of the identity, mailbox and write-back stages, if run.
    .PARAMETER StateEntry
        The worker's sync state entry, if they have one, for the Entra object
        ID, confirmed address and write-back result.
    .PARAMETER RetryCount
        How many times calls for this worker were retried in this run.
    .OUTPUTS
        An ordered dictionary, ready to be written as one JSON line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [Parameter(Mandatory)] $Decision,
        $Change,
        $Stages,
        $StateEntry,
        [int] $RetryCount = 0
    )

    # The Entra object ID: from the sync state, or the one identity the decision matched.
    $objectId = Get-AuditValue $StateEntry 'entraObjectId'
    $matched  = @($Decision.EntraIdentities)
    if (-not $objectId -and $matched.Count -eq 1) { $objectId = Get-AuditValue $matched[0] 'id' }

    # The overall result: what a reader most wants to know about this worker.
    $result = if ($Log.Mode -eq 'DryRun') { 'Proposed' }
              elseif ($Stages) { $Stages.Outcome }
              elseif ($Change) { $Change.Outcome }
              else { 'NothingDone' }

    $line = New-AuditLine -Log $Log -EventName 'Worker'
    $line.employeeId         = $Decision.EmployeeId
    $line.hrisRecordCount    = @($Decision.HRISRecords).Count
    $line.proposedAction     = $Decision.Action
    $line.reason             = $Decision.Reason
    $line.changedAttributes  = @($Decision.Changes.Keys)
    $line.result             = $result
    $line.changeResult       = Get-AuditValue $Change 'Outcome'
    $line.changeReason       = Get-AuditValue $Change 'Reason'
    $line.stage              = Get-AuditValue $Stages 'Stage'
    $line.stageResult        = Get-AuditValue $Stages 'Outcome'
    $line.stageReason        = Get-AuditValue $Stages 'Reason'
    $line.entraObjectId      = $objectId
    $line.primarySmtpAddress = Get-AuditValue $StateEntry 'primarySmtpAddress'
    $line.writeBackResult    = Get-AuditValue $StateEntry 'writeBackResult'
    $line.retryCount         = $RetryCount
    $line
}

function Write-AuditEntry {
    <#
    .SYNOPSIS
        Appends one line to the run's audit file, as compact JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [Parameter(Mandatory)] $Entry
    )

    $json = ConvertTo-Json -InputObject $Entry -Compress -Depth 4
    [System.IO.File]::AppendAllText($Log.Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Write-AuditRunStarted {
    <#
    .SYNOPSIS
        Appends the RunStarted line: the run's mode and how many HRIS records were read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [int] $RecordCount,
        [datetime] $Today
    )

    $line = New-AuditLine -Log $Log -EventName 'RunStarted'
    $line.hrisRecordCount = $RecordCount
    $line.today           = $Today.ToString('yyyy-MM-dd')
    Write-AuditEntry -Log $Log -Entry $line
}

function Write-AuditUnmatched {
    <#
    .SYNOPSIS
        Appends one IdentityNotInHRIS line for each Entra identity with no HRIS record.
    .DESCRIPTION
        Records that these identities were seen and deliberately left
        unchanged: a worker missing from one HRIS file is never disabled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [AllowEmptyCollection()] [object[]] $Identities = @()
    )

    foreach ($identity in $Identities) {
        $line = New-AuditLine -Log $Log -EventName 'IdentityNotInHRIS'
        $line.employeeId    = Get-AuditValue $identity 'employeeId'
        $line.entraObjectId = Get-AuditValue $identity 'id'
        $line.result        = 'LeftUnchanged'
        $line.reason        = 'Entra identity has no HRIS record; a worker missing from one input is never disabled'
        Write-AuditEntry -Log $Log -Entry $line
    }
}

function Write-AuditRunCompleted {
    <#
    .SYNOPSIS
        Appends the RunCompleted line, with a count of each action and each final stage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [AllowEmptyCollection()] [object[]] $Decisions = @(),
        [AllowEmptyCollection()] [object[]] $Pipeline = @()
    )

    $actions = [ordered]@{}
    foreach ($group in $Decisions | Group-Object Action | Sort-Object Name) { $actions[$group.Name] = $group.Count }
    $stages = [ordered]@{}
    foreach ($group in $Pipeline | Group-Object Stage | Sort-Object Name) { $stages[$group.Name] = $group.Count }

    $line = New-AuditLine -Log $Log -EventName 'RunCompleted'
    $line.workerCount = $Decisions.Count
    $line.actions     = $actions
    $line.stages      = $stages
    Write-AuditEntry -Log $Log -Entry $line
}

function Write-AuditRunFailed {
    <#
    .SYNOPSIS
        Appends a RunFailed line when a run stops with an error, with the error message.
    .DESCRIPTION
        The Worker lines already written show how far the run got; this line
        records why it stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [string] $Message
    )

    $line = New-AuditLine -Log $Log -EventName 'RunFailed'
    $line.result = 'Failed'
    $line.reason = $Message
    Write-AuditEntry -Log $Log -Entry $line
}
#endregion

Export-ModuleMember -Function New-AuditLog, ConvertTo-AuditEntry, Write-AuditEntry,
    Write-AuditRunStarted, Write-AuditRunCompleted, Write-AuditRunFailed, Write-AuditUnmatched
