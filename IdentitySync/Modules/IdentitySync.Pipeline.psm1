<#
.SYNOPSIS
    Applies identity decisions and runs each worker through the three stages:
    identity ready, mailbox ready, and email written back to the HRIS.

.DESCRIPTION
    Uses the decision rules in IdentitySync.psm1 to work out what to do, then
    does it with the Microsoft Graph and Exchange Online commands (Get-MgUser,
    New-MgUser, Update-MgUser, Set-MgUserManagerByRef, Get-EXOMailbox) and the
    HRIS API (Set-HRISWorkerEmail). With the mocks loaded these are the mock
    versions; in production they are the real modules.

    Changes to existing identities:
      Update    Department and manager changed with Update-MgUser and
                Set-MgUserManagerByRef.
      Disable   Account disabled with Update-MgUser -AccountEnabled:$false,
                unless more disables are planned than MaxDisablesPerRun, in
                which case none are applied: a large number of leavers at once
                more likely means a bad HRIS export than real departures.

    Every active worker then goes through three stages, each recorded in the
    sync state so a later run carries on where this one stopped:

      Pending -> IdentityReady -> MailboxReady -> Complete
                      |               |               |
                IdentityFailed  MailboxPending  WriteBackFailed
                  (retried)       (retried)       (retried)
                                      |
                                MailboxTimeout   ManualReview
                                (stops: needs    (stops: HRIS has a
                                 a person)        different address,
                                                  or the match is ambiguous)

      1. Identity ready   The worker's Entra identity exists. A joiner is
                          created with New-MgUser; an existing identity is
                          found with Get-MgUser. Before creating, Entra is
                          always checked, so a lost state file can never cause
                          a duplicate.
      2. Mailbox ready    Get-EXOMailbox finds the mailbox. A few checks are
                          made per run (MaxMailboxChecksPerRun), never an
                          endless wait. If it is still missing after
                          MailboxTimeoutHours, the worker stops at
                          MailboxTimeout for a person to look at.
      3. Written back     The PrimarySmtpAddress Exchange assigned (never the
                          requested address) is written to the HRIS worker
                          with the same employeeId, with an idempotency key.
                          Same address already there: NoChange. A different
                          address: ManualReview, never overwritten.

    Retries happen at two levels:
      Within a run    Every call to Graph, Exchange and the HRIS goes through
                      Invoke-WithRetry (IdentitySync.Retry.psm1): a 429, 502,
                      503 or 504 is retried with exponential back-off, up to
                      RetryMaxAttempts. Only after that does the stage fail.
      Across runs     A failed stage leaves the earlier stages done, so only
                      the failed stage is tried again on the next run.
    Workers that reach Complete, ManualReview or MailboxTimeout are not
    processed again.

    Retrying a create is made safe by looking before every attempt (see the
    identity stage), and retrying the HRIS write is safe because of its
    idempotency key.

    Public functions:
      New-SyncState          An empty sync state.
      Read-SyncState         Reads the sync state file, or starts a new one.
      Save-SyncState         Writes the sync state file.
      Get-SyncSettings       The default settings, with any overrides applied.
      Invoke-IdentitySyncRun Decides, and with -Apply applies, a whole run.
#>

Set-StrictMode -Version Latest

#region Settings and constants
# Default settings. Any of these can be overridden with Get-SyncSettings -Override.
$script:DefaultSettings = @{
    MaxMailboxChecksPerRun   = 3      # Get-EXOMailbox calls per worker per run
    MailboxCheckDelaySeconds = 0      # wait between those calls (raise for real Exchange)
    MailboxTimeoutHours      = 24     # after this, a missing mailbox stops at MailboxTimeout
    MaxDisablesPerRun        = 5      # more planned disables than this and none are applied
    UpnDomain                = 'example.com'
    RetryMaxAttempts         = 4      # attempts per call on 429, 502, 503 or 504, including the first
    RetryBaseDelaySeconds    = 2      # first wait between attempts; doubles each time (2, 4, 8)
    RetryMaxDelaySeconds     = 30     # the longest wait between attempts
}

# How calls are retried during a run: the settings and the -OnRetry callback.
# Set at the start of Invoke-IdentitySyncRun.
$script:RetryContext = @{ Settings = $script:DefaultSettings; OnRetry = $null }

# Stages that are finished, one way or another. Workers in these are skipped.
$script:FinalStages = @('Complete', 'ManualReview', 'MailboxTimeout')

# The fields every worker's state entry has.
$script:EntryFields = @('employeeId', 'stage', 'entraObjectId', 'primarySmtpAddress', 'identityReadyAt',
                        'mailboxChecks', 'writeBackResult', 'lastError', 'updatedAt')
#endregion

#region Private helpers
# Returns a property from an object, or $null when it is missing.
function Get-Value {
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Returns the HTTP status code of a failed call, or 0 if it was not an HTTP failure.
function Get-ErrorStatusCode {
    param($ErrorRecord)
    $code = $ErrorRecord.Exception.Data['StatusCode']
    if ($code) { return [int] $code }
    return 0
}

# The message for a failed call, saying how many attempts were made when it was retried.
function Get-FailureMessage {
    param($ErrorRecord)
    $attempts = [int] $ErrorRecord.Exception.Data['Attempts']
    if ($attempts -gt 1) { return '{0} (gave up after {1} attempts)' -f $ErrorRecord.Exception.Message, $attempts }
    $ErrorRecord.Exception.Message
}

# Makes one call to an external service, retrying transient failures (429,
# 502, 503, 504) with exponential back-off, using the run's retry settings.
function Invoke-ServiceCall {
    param([string] $Description, [scriptblock] $Action)

    $settings = $script:RetryContext.Settings
    Invoke-WithRetry -Action $Action -Description $Description -OnRetry $script:RetryContext.OnRetry `
        -MaxAttempts $settings.RetryMaxAttempts -BaseDelaySeconds $settings.RetryBaseDelaySeconds `
        -MaxDelaySeconds $settings.RetryMaxDelaySeconds
}

# Turns a timestamp from the state file back into a DateTime. PowerShell 7
# already converts ISO dates when reading JSON; Windows PowerShell 5.1 does not.
function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or [string] $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [datetime]::Parse([string] $Value, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

# A strong random password for a new account. It is passed straight to
# New-MgUser and never printed, logged or saved.
function New-RandomPassword {
    $bytes = [byte[]]::new(24)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    # The suffix guarantees upper case, lower case, a digit and a symbol.
    [Convert]::ToBase64String($bytes) + 'Aa1!'
}

# Converts a user from Get-MgUser into the shape the decision rules and the
# display use, with the manager's employeeId taken from -ExpandProperty manager.
function ConvertFrom-MgUser {
    param($User)

    $manager = Get-Value $User 'Manager'
    [pscustomobject]@{
        id                = $User.Id
        employeeId        = $User.EmployeeId
        accountEnabled    = $User.AccountEnabled
        givenName         = $User.GivenName
        surname           = $User.Surname
        department        = $User.Department
        managerEmployeeId = if ($manager) { Get-Value $manager.AdditionalProperties 'employeeId' } else { $null }
        mail              = $User.Mail
        userPrincipalName = $User.UserPrincipalName
    }
}

# Reads every Entra identity, with their managers.
function Get-EntraIdentity {
    $users = Invoke-ServiceCall 'Get-MgUser -All' { @(Get-MgUser -All -ExpandProperty manager) }
    @($users | ForEach-Object { ConvertFrom-MgUser $_ })
}

# Finds the object ID of the one Entra user with this employeeId, or $null
# when there is not exactly one.
function Find-ManagerObjectId {
    param([string] $EmployeeId)
    if (-not $EmployeeId) { return $null }
    $found = @(Invoke-ServiceCall "Get-MgUser $EmployeeId" { Get-MgUser -Filter "employeeId eq '$EmployeeId'" })
    if ($found.Count -eq 1) { return $found[0].Id }
    return $null
}

# Sets a user's manager by the manager's employeeId. Returns a note when the
# manager cannot be set, or nothing when it was set.
function Set-ManagerByEmployeeId {
    param([string] $UserId, [string] $ManagerEmployeeId)

    $managerObjectId = Find-ManagerObjectId -EmployeeId $ManagerEmployeeId
    if (-not $managerObjectId) {
        return "manager $ManagerEmployeeId not set: there is not exactly one Entra identity with that employeeId"
    }
    Invoke-ServiceCall "Set-MgUserManagerByRef $ManagerEmployeeId" {
        Set-MgUserManagerByRef -UserId $UserId -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$managerObjectId" }
    }
}

# Builds the result returned for one change or one worker's pipeline.
function New-StepResult {
    param([string] $EmployeeId, [string] $Name, [string] $Stage, [string] $Outcome, [string] $Reason)
    [pscustomobject]@{
        EmployeeId = $EmployeeId
        Name       = $Name
        Stage      = $Stage
        Outcome    = $Outcome
        Reason     = $Reason
    }
}

# Returns the state entry for an employeeId, creating a Pending one if needed.
function Get-StateEntry {
    param($State, [string] $EmployeeId)

    if (-not $State.workers.ContainsKey($EmployeeId)) {
        $entry = [ordered]@{}
        foreach ($field in $script:EntryFields) { $entry[$field] = $null }
        $entry.employeeId    = $EmployeeId
        $entry.stage         = 'Pending'
        $entry.mailboxChecks = 0
        $State.workers[$EmployeeId] = [pscustomobject] $entry
    }
    $State.workers[$EmployeeId]
}

# Records a stage change on a state entry and lets the caller save it.
function Set-EntryStage {
    param($Entry, [string] $Stage, [string] $LastError, [datetime] $Now, [scriptblock] $OnChange)

    $Entry.stage     = $Stage
    $Entry.lastError = $LastError
    $Entry.updatedAt = $Now.ToString('o')
    if ($OnChange) { & $OnChange }
}
#endregion

#region Sync state
function New-SyncState {
    <#
    .SYNOPSIS
        Returns an empty sync state: no workers in progress.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        version   = 1
        updatedAt = $null
        workers   = @{}
    }
}

function Read-SyncState {
    <#
    .SYNOPSIS
        Reads the sync state file, or returns a new state if there is none yet.
    .DESCRIPTION
        The file records, for each worker, which stage they have reached and
        what was learned on the way (Entra object ID, primary SMTP address,
        when the identity became ready), so a run can carry on after a restart.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $saved = Read-JsonFile -Path $Path -Description 'Sync state'
    $state = New-SyncState
    if ($null -eq $saved) { return $state }

    $state.updatedAt = Get-Value $saved 'updatedAt'
    $workers = Get-Value $saved 'workers'
    if ($workers) {
        foreach ($property in $workers.PSObject.Properties) {
            # Every entry gets every field, so older or hand-edited files still work.
            $entry = [ordered]@{}
            foreach ($field in $script:EntryFields) { $entry[$field] = Get-Value $property.Value $field }
            if ($null -eq $entry.mailboxChecks) { $entry.mailboxChecks = 0 }
            $state.workers[$property.Name] = [pscustomobject] $entry
        }
    }
    $state
}

function Save-SyncState {
    <#
    .SYNOPSIS
        Writes the sync state file, safely (temporary file, then moved into place).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Path
    )
    $State.updatedAt = [datetime]::UtcNow.ToString('o')
    Write-JsonFile -Path $Path -InputObject $State
}

function Get-SyncSettings {
    <#
    .SYNOPSIS
        Returns the default sync settings, with any overrides applied.
    .EXAMPLE
        Get-SyncSettings -Override @{ MaxMailboxChecksPerRun = 1 }
    #>
    [CmdletBinding()]
    param([hashtable] $Override = @{})

    $settings = $script:DefaultSettings.Clone()
    foreach ($key in $Override.Keys) {
        if (-not $settings.ContainsKey($key)) { throw "Unknown sync setting: $key" }
        $settings[$key] = $Override[$key]
    }
    $settings
}
#endregion

#region Changes to existing identities
# Applies an Update or Disable decision to the worker's existing Entra identity.
function Invoke-IdentityChange {
    param($Decision, [hashtable] $Settings)

    $identity = @($Decision.EntraIdentities)[0]
    $result   = @{ EmployeeId = $Decision.EmployeeId; Name = $Decision.Name; Stage = $Decision.Action }
    try {
        if ($Decision.Action -eq 'Disable') {
            Invoke-ServiceCall "Update-MgUser $($Decision.EmployeeId)" { Update-MgUser -UserId $identity.id -AccountEnabled:$false }
            return New-StepResult @result -Outcome 'Done' -Reason 'Account disabled'
        }

        # Update: department and manager are the only attributes an Update changes.
        $notes = @()
        if ($Decision.Changes.Contains('department')) {
            Invoke-ServiceCall "Update-MgUser $($Decision.EmployeeId)" { Update-MgUser -UserId $identity.id -Department $Decision.Changes['department'].To }
        }
        if ($Decision.Changes.Contains('managerEmployeeId')) {
            $note = Set-ManagerByEmployeeId -UserId $identity.id -ManagerEmployeeId $Decision.Changes['managerEmployeeId'].To
            if ($note) { $notes += $note }
        }
        $reason = 'Changed {0}' -f (@($Decision.Changes.Keys) -join ', ')
        if ($notes) { $reason = '{0}; {1}' -f $reason, ($notes -join '; ') }
        return New-StepResult @result -Outcome $(if ($notes) { 'Partial' } else { 'Done' }) -Reason $reason
    }
    catch {
        # Nothing is saved for changes: the next run re-plans and tries again.
        return New-StepResult @result -Outcome 'Failed' -Reason "Will be retried on the next run: $(Get-FailureMessage $_)"
    }
}
#endregion

#region Worker pipeline
# Runs one worker through whichever stages are left, recording each in their
# state entry. Returns the result of the last stage reached.
function Invoke-WorkerPipeline {
    param(
        $Decision,
        $Entry,
        [hashtable] $Settings,
        [datetime] $Now,
        [string] $HRISToken,
        [scriptblock] $OnChange
    )

    $employeeId = $Decision.EmployeeId
    $name       = $Decision.Name
    $worker     = @($Decision.HRISRecords)[0]

    # Finished workers are left alone.
    if ($script:FinalStages -contains $Entry.stage) {
        return New-StepResult $employeeId $name $Entry.stage 'Skipped' "Already $($Entry.stage) in an earlier run"
    }

    # Stage 1: the Entra identity.
    if (-not $Entry.entraObjectId) {
        try {
            # Look, then create only if nothing was found. Both happen inside one
            # retried call, so every attempt looks first: if a create reached
            # Entra but its response was lost, the retry finds that identity
            # instead of making a duplicate. This is also what stops a lost
            # state file from causing a duplicate.
            $firstName = Get-Value $worker 'firstName'
            $lastName  = Get-Value $worker 'lastName'
            $outcome = Invoke-ServiceCall "Get-MgUser / New-MgUser $employeeId" {
                $found = @(Get-MgUser -Filter "employeeId eq '$employeeId'")
                if ($found.Count -gt 0 -or $Decision.Action -ne 'Create') {
                    return [pscustomobject]@{ Existing = $found; Created = $null }
                }
                $newUser = New-MgUser -AccountEnabled `
                    -DisplayName "$firstName $lastName" -GivenName $firstName -Surname $lastName `
                    -Department (Get-Value $worker 'department') -EmployeeId $employeeId `
                    -MailNickname ("$firstName.$lastName".ToLowerInvariant() -replace '[^a-z0-9.]', '') `
                    -UserPrincipalName "$employeeId@$($Settings.UpnDomain)" `
                    -PasswordProfile @{ Password = (New-RandomPassword); ForceChangePasswordNextSignIn = $true }
                [pscustomobject]@{ Existing = @(); Created = $newUser }
            }
            $existing = @($outcome.Existing)
            $user     = $outcome.Created

            if ($existing.Count -gt 1) {
                Set-EntryStage $Entry 'ManualReview' "$($existing.Count) Entra identities have employeeId $employeeId" $Now $OnChange
                return New-StepResult $employeeId $name 'ManualReview' 'Stopped' $Entry.lastError
            }

            $note = $null
            if ($existing.Count -eq 1) {
                $Entry.entraObjectId   = $existing[0].Id
                $Entry.identityReadyAt = $Now.ToString('o')
            }
            elseif ($user) {
                $Entry.entraObjectId   = $user.Id
                $Entry.identityReadyAt = $Now.ToString('o')

                # Saved straight away, so a failure from here on can never cause a second create.
                Set-EntryStage $Entry 'IdentityReady' $null $Now $OnChange

                # A manager that cannot be set is noted, but does not hold up the mailbox or write-back.
                $managerId = Get-Value $worker 'managerEmployeeId'
                if ($managerId) {
                    try { $note = Set-ManagerByEmployeeId -UserId $user.Id -ManagerEmployeeId $managerId }
                    catch { $note = "manager $managerId not set: $(Get-FailureMessage $_)" }
                }
            }
            else {
                Set-EntryStage $Entry 'IdentityFailed' "No Entra identity for $employeeId, and the decision ($($Decision.Action)) does not create one" $Now $OnChange
                return New-StepResult $employeeId $name 'IdentityFailed' 'Failed' $Entry.lastError
            }

            Set-EntryStage $Entry 'IdentityReady' $note $Now $OnChange
        }
        catch {
            # The identity may or may not exist; the next run looks it up again first.
            Set-EntryStage $Entry 'IdentityFailed' (Get-FailureMessage $_) $Now $OnChange
            return New-StepResult $employeeId $name 'IdentityFailed' 'Failed' "Will be retried on the next run: $($Entry.lastError)"
        }
    }

    # Stage 2: the mailbox and its primary SMTP address.
    if ($Entry.stage -in 'Pending', 'IdentityReady', 'IdentityFailed', 'MailboxPending') {
        $mailbox   = $null
        $lastError = $null
        for ($check = 1; $check -le $Settings.MaxMailboxChecksPerRun; $check++) {
            $Entry.mailboxChecks = [int] $Entry.mailboxChecks + 1
            try {
                # Transient failures are retried inside the call; a 404 (not provisioned yet) is not.
                $mailbox = Invoke-ServiceCall "Get-EXOMailbox $employeeId" { Get-EXOMailbox -Identity $Entry.entraObjectId }
                break
            }
            catch {
                # 404 means not provisioned yet; anything else is kept as the reason.
                if ((Get-ErrorStatusCode $_) -ne 404) { $lastError = Get-FailureMessage $_ }
                if ($check -lt $Settings.MaxMailboxChecksPerRun -and $Settings.MailboxCheckDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $Settings.MailboxCheckDelaySeconds
                }
            }
        }

        if ($null -eq $mailbox) {
            # Never wait indefinitely: after the timeout, stop and let a person look.
            $readyAt = ConvertTo-UtcDate $Entry.identityReadyAt
            if (-not $readyAt) { $readyAt = $Now }
            $waited = $Now - $readyAt
            if ($waited.TotalHours -ge $Settings.MailboxTimeoutHours) {
                $reason = 'No mailbox {0:N1} hours after the identity was ready (limit {1}); needs a person to check licensing and provisioning' -f $waited.TotalHours, $Settings.MailboxTimeoutHours
                Set-EntryStage $Entry 'MailboxTimeout' $reason $Now $OnChange
                return New-StepResult $employeeId $name 'MailboxTimeout' 'Stopped' $reason
            }

            $reason = if ($lastError) { $lastError } else { "Mailbox not provisioned yet after $($Entry.mailboxChecks) check(s); no HRIS write-back until it is" }
            Set-EntryStage $Entry 'MailboxPending' $reason $Now $OnChange
            return New-StepResult $employeeId $name 'MailboxPending' 'Waiting' "Will be checked again on the next run: $reason"
        }

        $Entry.primarySmtpAddress = $mailbox.PrimarySmtpAddress
        Set-EntryStage $Entry 'MailboxReady' $null $Now $OnChange
    }

    # Stage 3: write the confirmed address back to the HRIS.
    if ($Entry.stage -in 'MailboxReady', 'WriteBackFailed') {
        $address = $Entry.primarySmtpAddress
        try {
            # The idempotency key makes retrying this write safe: a repeat is never applied twice.
            $result = Invoke-ServiceCall "Set-HRISWorkerEmail $employeeId" {
                Set-HRISWorkerEmail -EmployeeId $employeeId -Email $address -IdempotencyKey "$employeeId`:$address" -Token $HRISToken
            }
            $Entry.writeBackResult = $result.Result
            Set-EntryStage $Entry 'Complete' $null $Now $OnChange

            $reason = if ($result.Result -eq 'NoChange') { "HRIS already had $address" } else { "Wrote $address to the HRIS" }
            return New-StepResult $employeeId $name 'Complete' $result.Result $reason
        }
        catch {
            if ((Get-ErrorStatusCode $_) -eq 409) {
                # A different address is already in the HRIS: never overwritten, a person decides.
                Set-EntryStage $Entry 'ManualReview' $_.Exception.Message $Now $OnChange
                return New-StepResult $employeeId $name 'ManualReview' 'Stopped' "Exchange assigned $address, but $($Entry.lastError)"
            }
            # Only this stage is retried next run: the identity and mailbox are already done.
            Set-EntryStage $Entry 'WriteBackFailed' (Get-FailureMessage $_) $Now $OnChange
            return New-StepResult $employeeId $name 'WriteBackFailed' 'Failed' "Only the write-back will be retried on the next run: $($Entry.lastError)"
        }
    }

    New-StepResult $employeeId $name $Entry.stage 'Unknown' "Unexpected stage $($Entry.stage)"
}
#endregion

#region Run
function Invoke-IdentitySyncRun {
    <#
    .SYNOPSIS
        Decides, and with -Apply applies, one identity sync run.
    .DESCRIPTION
        Reads the current Entra identities with Get-MgUser, decides an action
        for every HRIS worker, and returns the decisions. With -Apply it also
        applies Update and Disable decisions and runs every active worker
        through the identity, mailbox and write-back stages, recording each
        stage in -State.

        Without -Apply nothing is changed: no Graph, Exchange or HRIS write is
        made and -State is not touched.
    .PARAMETER Workers
        The HRIS worker records for this run.
    .PARAMETER State
        The sync state from Read-SyncState. Updated in place.
    .PARAMETER Apply
        Make changes. Without it, the run is a dry run.
    .PARAMETER Today
        The date the decision rules treat as today.
    .PARAMETER Now
        The time used for state timestamps and the mailbox timeout.
    .PARAMETER HRISToken
        The HRIS API token for the write-back. Never printed or saved.
    .PARAMETER Settings
        From Get-SyncSettings.
    .PARAMETER OnChange
        Run after every stage change, to save the state straight away.
    .PARAMETER OnDecision
        Run with each decision, its position and the total, before anything
        is done for that worker, so the caller can print it.
    .PARAMETER OnRetry
        Run before each wait when a call is retried, with details of the
        retry (see Invoke-WithRetry), so the caller can show it.
    .PARAMETER OnWorkerDone
        Run with each decision, its change result and its stage result (either
        can be $null) once everything for that worker is done. Also run on a
        dry run, with both results $null, so every worker can be audited.
    .OUTPUTS
        An object with Identities, Decisions, Unmatched, Changes, Pipeline and Applied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Workers,
        [Parameter(Mandatory)] $State,
        [switch] $Apply,
        [datetime] $Today = (Get-Date).Date,
        [datetime] $Now = [datetime]::UtcNow,
        [string] $HRISToken,
        [hashtable] $Settings = (Get-SyncSettings),
        [scriptblock] $OnChange,
        [scriptblock] $OnDecision,
        [scriptblock] $OnWorkerDone,
        [scriptblock] $OnRetry
    )

    # Every call to Graph, Exchange and the HRIS in this run uses these retry settings.
    $script:RetryContext = @{ Settings = $Settings; OnRetry = $OnRetry }

    $identities = Get-EntraIdentity
    $decisions  = @(Get-IdentityPlan -Workers $Workers -Identities $identities -Today $Today)
    $unmatched  = @(Get-UnmatchedIdentity -Workers $Workers -Identities $identities)

    $changes  = [System.Collections.Generic.List[object]]::new()
    $pipeline = [System.Collections.Generic.List[object]]::new()

    # Too many disables at once are all held back, so this is worked out before any worker.
    $disables     = @($decisions | Where-Object { $_.Action -eq 'Disable' })
    $holdDisables = $disables.Count -gt $Settings.MaxDisablesPerRun

    # One worker at a time: their change to an existing identity, then their
    # stages, so everything done for a worker happens (and is reported) together.
    for ($i = 0; $i -lt $decisions.Count; $i++) {
        $decision = $decisions[$i]
        if ($OnDecision) { & $OnDecision $decision ($i + 1) $decisions.Count }
        if (-not $Apply) {
            # Nothing is done on a dry run, but the caller still hears about every worker (for the audit log).
            if ($OnWorkerDone) { & $OnWorkerDone $decision $null $null }
            continue
        }

        $change = $null
        if ($decision.Action -eq 'Disable' -and $holdDisables) {
            $change = New-StepResult $decision.EmployeeId $decision.Name 'Disable' 'Skipped' (
                '{0} disables planned, more than the limit of {1} per run; none applied. Check the HRIS export.' -f $disables.Count, $Settings.MaxDisablesPerRun)
        }
        elseif ($decision.Action -in 'Update', 'Disable') {
            $change = Invoke-IdentityChange -Decision $decision -Settings $Settings
        }
        if ($change) { $changes.Add($change) }

        # The three stages, for every active worker whose record could be handled.
        $stages = $null
        $eligible = ($decision.Action -in 'Create', 'Update', 'NoChange') -and
                    (@($decision.HRISRecords).Count -eq 1) -and
                    ((Get-Value @($decision.HRISRecords)[0] 'status') -ceq 'Active')
        if ($eligible) {
            $entry  = Get-StateEntry -State $State -EmployeeId $decision.EmployeeId
            $stages = Invoke-WorkerPipeline -Decision $decision -Entry $entry -Settings $Settings -Now $Now -HRISToken $HRISToken -OnChange $OnChange
            $pipeline.Add($stages)
        }

        if ($OnWorkerDone) { & $OnWorkerDone $decision $change $stages }
    }

    [pscustomobject]@{
        Identities = $identities
        Decisions  = $decisions
        Unmatched  = $unmatched
        Changes    = $changes.ToArray()
        Pipeline   = $pipeline.ToArray()
        Applied    = [bool] $Apply
    }
}
#endregion

Export-ModuleMember -Function New-SyncState, Read-SyncState, Save-SyncState, Get-SyncSettings, Invoke-IdentitySyncRun
