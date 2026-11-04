<#
.SYNOPSIS
    Pester tests for applying decisions and the identity, mailbox and HRIS
    write-back stages.

.DESCRIPTION
    Each test sets up the mock services with a few records, runs
    Invoke-IdentitySyncRun once or more, and checks the stage reached, what
    changed in Entra ID and the HRIS, and that nothing was done twice. Covers
    the brief's cases: successful write-back, assigned address differing from
    the requested one, mailbox not ready, mailbox timeout, write-back failure
    (retrying only that stage), conflicting and matching emails, transient
    failures, restarting part-way, a lost state file, re-running the same
    input, and the disable safety limit.

    Run from the repository root with:
        Invoke-Pester ./Tests
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '..\IdentitySync\Modules'
    foreach ($module in 'IdentitySync.psm1', 'IdentitySync.Files.psm1', 'IdentitySync.Mocks.psm1', 'IdentitySync.Pipeline.psm1') {
        Import-Module (Join-Path $modules $module) -Force
    }
    Set-MockActivityOutput -Enabled $false

    $script:Token = 'test-token'
    $script:Today = [datetime] '2026-11-04'
    $script:Now   = [datetime]::new(2026, 11, 4, 9, 0, 0, [System.DateTimeKind]::Utc)

    # An HRIS worker. Defaults to an active joiner, Sam Jones, managed by E1008.
    function New-Worker {
        param(
            [string] $EmployeeId = 'E2001', [string] $FirstName = 'Sam', [string] $LastName = 'Jones',
            [string] $Department = 'IT', [string] $Status = 'Active', [string] $EndDate, [string] $Email
        )
        [pscustomobject]@{
            employeeId = $EmployeeId; status = $Status; firstName = $FirstName; lastName = $LastName
            department = $Department; managerEmployeeId = 'E1008'; startDate = '2026-01-05'
            endDate = if ($EndDate) { $EndDate } else { $null }
            email   = if ($Email) { $Email } else { $null }
        }
    }

    # An existing Entra identity. The manager, E1008, is always included by Initialize-Run.
    function New-Identity {
        param(
            [string] $EmployeeId, [string] $FirstName = 'Sam', [string] $LastName = 'Jones',
            [string] $Department = 'IT', [string] $Mail, [string] $ManagerEmployeeId = 'E1008'
        )
        [pscustomobject]@{
            id = "00000000-0000-4000-8000-00000000$($EmployeeId.Substring(1).PadLeft(4, '0'))"
            employeeId = $EmployeeId; accountEnabled = $true; givenName = $FirstName; surname = $LastName
            department = $Department; managerEmployeeId = $ManagerEmployeeId; mail = $Mail
        }
    }

    # Sets up the mock services for a run, as Invoke-IdentitySync.ps1 does, and
    # returns a fresh sync state.
    function Initialize-Run {
        param([object[]] $Identities = @(), [object[]] $Workers = @(), $Behaviour, [string] $FromPath)
        $manager = New-Identity -EmployeeId 'E1008' -FirstName 'Robin' -LastName 'Lee' -Department 'IT' -Mail 'robin.lee@example.com' -ManagerEmployeeId ''
        Initialize-MockServices -Identities (@($manager) + @($Identities)) -Workers $Workers -Behaviour $Behaviour -HRISApiToken $Token -FromPath $FromPath
        Connect-MgGraph -Identity
        Connect-ExchangeOnline -ManagedIdentity -Organization 'example.onmicrosoft.com'
        New-SyncState
    }

    # Runs one sync with -Apply and returns the run.
    function Invoke-Run {
        param(
            [object[]] $Workers, $State, [datetime] $At = $Now, [hashtable] $Override = @{}, [switch] $DryRun
        )
        Invoke-IdentitySyncRun -Workers $Workers -State $State -Apply:(-not $DryRun) -Today $Today -Now $At `
            -HRISToken $Token -Settings (Get-SyncSettings -Override $Override)
    }

    # Returns the pipeline result for one employeeId from a run.
    function Get-Result {
        param($Run, [string] $EmployeeId)
        @($Run.Pipeline | Where-Object { $_.EmployeeId -eq $EmployeeId })[0]
    }

    # How many Entra users have this employeeId, and the HRIS email for a worker.
    function Get-EntraCount { param([string] $EmployeeId) @(Get-MgUser -Filter "employeeId eq '$EmployeeId'").Count }
    function Get-HRISEmail  { param([string] $EmployeeId) (Get-HRISWorker -EmployeeId $EmployeeId -Token $Token).email }

    # Behaviour settings, built inline so each test shows exactly what it simulates.
    function New-Behaviour {
        param([int] $ReadyAfterChecks = 2, [string[]] $NeverReady = @(), [hashtable] $EntraFailures = @{}, [hashtable] $HRISFailures = @{})
        $toFailures = { param($table) $o = [pscustomobject]@{}; foreach ($k in $table.Keys) { $o | Add-Member $k ([pscustomobject] $table[$k]) }; $o }
        [pscustomobject]@{
            mailDomain = 'example.com'
            entra      = [pscustomobject]@{ failures = (& $toFailures $EntraFailures) }
            exchange   = [pscustomobject]@{ readyAfterChecks = $ReadyAfterChecks; neverReady = $NeverReady }
            HRIS       = [pscustomobject]@{ failures = (& $toFailures $HRISFailures) }
        }
    }
}

Describe 'Dry run' {
    It 'changes nothing in Entra ID or the HRIS, and leaves the state empty' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers
        $run     = Invoke-Run -Workers $workers -State $state -DryRun

        $run.Decisions[0].Action | Should -Be 'Create'
        $run.Pipeline | Should -HaveCount 0
        Get-EntraCount 'E2001' | Should -Be 0
        $state.workers.Count | Should -Be 0
    }
}

Describe 'New joiner' {
    It 'goes through all three stages in one run when the mailbox is quick' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers
        $result  = Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001'

        $result.Stage | Should -Be 'Complete'
        $result.Outcome | Should -Be 'Updated'
        Get-HRISEmail 'E2001' | Should -Be 'sam.jones@example.com'
    }

    It 'creates an enabled identity with the manager set' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers
        Invoke-Run -Workers $workers -State $state | Out-Null

        $user = Get-MgUser -Filter "employeeId eq 'E2001'" -ExpandProperty manager
        $user.AccountEnabled | Should -BeTrue
        $user.Manager.AdditionalProperties['employeeId'] | Should -Be 'E1008'
    }

    It 'records the Entra object ID and confirmed address in the state' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers
        Invoke-Run -Workers $workers -State $state | Out-Null

        $entry = $state.workers['E2001']
        $entry.entraObjectId | Should -Be (Get-MgUser -Filter "employeeId eq 'E2001'").Id
        $entry.primarySmtpAddress | Should -Be 'sam.jones@example.com'
        $entry.writeBackResult | Should -Be 'Updated'
    }

    It 'writes back the address Exchange assigned, not the one requested' {
        # Someone already has sam.jones@, so Exchange assigns sam.jones2@ to the joiner.
        $existing = New-Identity -EmployeeId 'E1500' -Mail 'sam.jones@example.com'
        $workers  = @((New-Worker -EmployeeId 'E1500' -Email 'sam.jones@example.com'), (New-Worker))
        $state    = Initialize-Run -Identities @($existing) -Workers $workers
        Invoke-Run -Workers $workers -State $state | Out-Null

        $state.workers['E2001'].primarySmtpAddress | Should -Be 'sam.jones2@example.com'
        Get-HRISEmail 'E2001' | Should -Be 'sam.jones2@example.com'
    }
}

Describe 'Mailbox not ready' {
    It 'waits without writing back, then finishes on a later run without creating the identity again' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -ReadyAfterChecks 5)

        $first = Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001'
        $first.Stage | Should -Be 'MailboxPending'
        Get-HRISEmail 'E2001' | Should -BeNullOrEmpty

        $second = Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001'
        $second.Stage | Should -Be 'Complete'
        Get-EntraCount 'E2001' | Should -Be 1
    }

    It 'makes only a bounded number of checks in one run' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -NeverReady 'E2001')
        Invoke-Run -Workers $workers -State $state -Override @{ MaxMailboxChecksPerRun = 3 } | Out-Null

        $state.workers['E2001'].mailboxChecks | Should -Be 3
    }

    It 'stops at MailboxTimeout once the timeout has passed, with no write-back' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -NeverReady 'E2001')

        (Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001').Stage | Should -Be 'MailboxPending'
        (Get-Result (Invoke-Run -Workers $workers -State $state -At $Now.AddHours(25)) 'E2001').Stage | Should -Be 'MailboxTimeout'
        Get-HRISEmail 'E2001' | Should -BeNullOrEmpty
    }

    It 'leaves a timed-out worker alone on later runs' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -NeverReady 'E2001')
        Invoke-Run -Workers $workers -State $state | Out-Null
        Invoke-Run -Workers $workers -State $state -At $Now.AddHours(25) | Out-Null

        (Get-Result (Invoke-Run -Workers $workers -State $state -At $Now.AddHours(26)) 'E2001').Outcome | Should -Be 'Skipped'
    }
}

Describe 'HRIS write-back' {
    It 'retries only the write-back after it fails, without recreating the identity' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -HRISFailures @{ E2001 = @{ statusCode = 503; times = 1 } })

        $first = Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001'
        $first.Stage | Should -Be 'WriteBackFailed'
        $objectId = $state.workers['E2001'].entraObjectId

        $second = Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001'
        $second.Stage | Should -Be 'Complete'
        $state.workers['E2001'].entraObjectId | Should -Be $objectId
        Get-EntraCount 'E2001' | Should -Be 1
        Get-HRISEmail 'E2001' | Should -Be 'sam.jones@example.com'
    }

    It 'returns NoChange when the HRIS already has the confirmed address' {
        $existing = New-Identity -EmployeeId 'E1500' -Mail 'sam.jones@example.com'
        $workers  = @(New-Worker -EmployeeId 'E1500' -Email 'sam.jones@example.com')
        $state    = Initialize-Run -Identities @($existing) -Workers $workers
        $result   = Get-Result (Invoke-Run -Workers $workers -State $state) 'E1500'

        $result.Stage | Should -Be 'Complete'
        $result.Outcome | Should -Be 'NoChange'
    }

    It 'stops at ManualReview, without overwriting, when the HRIS has a different address' {
        $existing = New-Identity -EmployeeId 'E1500' -Mail 'sam.jones@example.com'
        $workers  = @(New-Worker -EmployeeId 'E1500' -Email 'old.address@example.com')
        $state    = Initialize-Run -Identities @($existing) -Workers $workers
        $result   = Get-Result (Invoke-Run -Workers $workers -State $state) 'E1500'

        $result.Stage | Should -Be 'ManualReview'
        Get-HRISEmail 'E1500' | Should -Be 'old.address@example.com'
    }
}

Describe 'Transient identity failure' {
    It 'records IdentityFailed without creating anything, then succeeds on a later run' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -EntraFailures @{ E2001 = @{ statusCode = 503; times = 1 } })

        $first = Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001'
        $first.Stage | Should -Be 'IdentityFailed'
        $first.Reason | Should -Match 'HTTP 503'
        Get-EntraCount 'E2001' | Should -Be 0

        (Get-Result (Invoke-Run -Workers $workers -State $state) 'E2001').Stage | Should -Be 'Complete'
        Get-EntraCount 'E2001' | Should -Be 1
    }
}

Describe 'Restart safety and idempotency' {
    BeforeEach {
        $script:Folder = Join-Path ([System.IO.Path]::GetTempPath()) ("identitysync-test-" + [guid]::NewGuid())
        $script:StateFile = Join-Path $Folder 'sync-state.json'
        $script:MockFile  = Join-Path $Folder 'mock-services.json'
    }
    AfterEach {
        if (Test-Path $Folder) { Remove-Item $Folder -Recurse -Force }
    }

    It 'carries on from the saved state after a restart, without creating the identity again' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -ReadyAfterChecks 5)
        Invoke-Run -Workers $workers -State $state | Out-Null
        Save-SyncState -State $state -Path $StateFile
        Save-MockServices -Path $MockFile

        # A new process: everything is read back from disk.
        Initialize-Run -Workers $workers -Behaviour (New-Behaviour -ReadyAfterChecks 5) -FromPath $MockFile | Out-Null
        $restored = Read-SyncState -Path $StateFile
        $restored.workers['E2001'].stage | Should -Be 'MailboxPending'

        (Get-Result (Invoke-Run -Workers $workers -State $restored) 'E2001').Stage | Should -Be 'Complete'
        Get-EntraCount 'E2001' | Should -Be 1
    }

    It 'finds the existing identity and carries on, without a duplicate, when the state file is lost' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers -Behaviour (New-Behaviour -ReadyAfterChecks 5)
        Invoke-Run -Workers $workers -State $state | Out-Null
        $objectId = $state.workers['E2001'].entraObjectId

        # The state is gone, but Entra still has the identity: it is found and used.
        $lostState = New-SyncState
        $result    = Get-Result (Invoke-Run -Workers $workers -State $lostState) 'E2001'

        $result.Stage | Should -Be 'Complete'
        $lostState.workers['E2001'].entraObjectId | Should -Be $objectId
        Get-EntraCount 'E2001' | Should -Be 1
    }

    It 'makes no changes when the same input is run again' {
        $workers = @((New-Worker), (New-Worker -EmployeeId 'E2002' -FirstName 'Alex' -LastName 'Kim'))
        $state   = Initialize-Run -Workers $workers
        Invoke-Run -Workers $workers -State $state | Out-Null

        $second = Invoke-Run -Workers $workers -State $state
        @($second.Pipeline.Outcome | Select-Object -Unique) | Should -Be @('Skipped')
        @($second.Decisions.Action | Select-Object -Unique) | Should -Be @('NoChange')
        Get-EntraCount 'E2001' | Should -Be 1
        Get-EntraCount 'E2002' | Should -Be 1
    }

    It 'never saves a password or token to the state files' {
        $workers = @(New-Worker)
        $state   = Initialize-Run -Workers $workers
        Invoke-Run -Workers $workers -State $state | Out-Null
        Save-SyncState -State $state -Path $StateFile
        Save-MockServices -Path $MockFile

        $saved = (Get-Content $StateFile -Raw) + (Get-Content $MockFile -Raw)
        $saved | Should -Not -Match '(?i)password'
        $saved | Should -Not -Match $Token
    }
}

Describe 'Changes to existing identities' {
    It 'applies a department and manager change' {
        $existing = New-Identity -EmployeeId 'E1500' -Department 'Operations' -ManagerEmployeeId 'E1009' -Mail 'sam.jones@example.com'
        $other    = New-Identity -EmployeeId 'E1009' -FirstName 'Kai' -LastName 'Ng' -Mail 'kai.ng@example.com'
        $workers  = @((New-Worker -EmployeeId 'E1500' -Department 'Finance' -Email 'sam.jones@example.com'),
                      (New-Worker -EmployeeId 'E1009' -FirstName 'Kai' -LastName 'Ng' -Email 'kai.ng@example.com'))
        $state    = Initialize-Run -Identities @($existing, $other) -Workers $workers
        $run      = Invoke-Run -Workers $workers -State $state

        @($run.Changes | Where-Object EmployeeId -eq 'E1500')[0].Outcome | Should -Be 'Done'
        $user = Get-MgUser -Filter "employeeId eq 'E1500'" -ExpandProperty manager
        $user.Department | Should -Be 'Finance'
        $user.Manager.AdditionalProperties['employeeId'] | Should -Be 'E1008'
    }

    It 'disables a leaver, and does not run them through the write-back stages' {
        $existing = New-Identity -EmployeeId 'E1500' -Mail 'sam.jones@example.com'
        $workers  = @(New-Worker -EmployeeId 'E1500' -Status 'Inactive' -EndDate '2026-11-01' -Email 'sam.jones@example.com')
        $state    = Initialize-Run -Identities @($existing) -Workers $workers
        $run      = Invoke-Run -Workers $workers -State $state

        $run.Changes[0].Outcome | Should -Be 'Done'
        (Get-MgUser -Filter "employeeId eq 'E1500'").AccountEnabled | Should -BeFalse
        $run.Pipeline | Should -HaveCount 0
    }

    It 'applies no disables at all when more are planned than the limit allows' {
        $ids      = 'E1501', 'E1502', 'E1503'
        $existing = foreach ($id in $ids) { New-Identity -EmployeeId $id -Mail "$id@example.com".ToLowerInvariant() }
        $workers  = foreach ($id in $ids) { New-Worker -EmployeeId $id -Status 'Inactive' -EndDate '2026-11-01' }
        $state    = Initialize-Run -Identities $existing -Workers $workers
        $run      = Invoke-Run -Workers $workers -State $state -Override @{ MaxDisablesPerRun = 2 }

        @($run.Changes.Outcome | Select-Object -Unique) | Should -Be @('Skipped')
        foreach ($id in $ids) { (Get-MgUser -Filter "employeeId eq '$id'").AccountEnabled | Should -BeTrue }
    }

    It 'does not run ManualReview decisions through the stages' {
        $workers = @((New-Worker), (New-Worker))
        $state   = Initialize-Run -Workers $workers
        $run     = Invoke-Run -Workers $workers -State $state

        $run.Decisions[0].Action | Should -Be 'ManualReview'
        $run.Pipeline | Should -HaveCount 0
        Get-EntraCount 'E2001' | Should -Be 0
    }
}

Describe 'Settings' {
    It 'rejects an unknown setting' {
        { Get-SyncSettings -Override @{ NoSuchSetting = 1 } } | Should -Throw '*Unknown sync setting*'
    }
}
