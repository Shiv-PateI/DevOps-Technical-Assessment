<#
.SYNOPSIS
    Pester tests for the Microsoft Graph, Exchange Online and HRIS mocks.

.DESCRIPTION
    Checks the mocks behave the way the sync will rely on, using the same
    commands as the real modules: Get-MgUser, New-MgUser, Update-MgUser,
    Set-MgUserManagerByRef and Get-EXOMailbox, plus the HRIS write-back API.
    Covers matching by employeeId, mailbox provisioning delays, assigned
    addresses, simulated HTTP failures, and the HRIS rules (authentication,
    validation, idempotency and conflicts). The last section loads the real
    mock files to confirm each configured test case is set up.

    Run from the repository root with:
        Invoke-Pester ./Tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\IdentitySync\Modules\IdentitySync.Mocks.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\IdentitySync\Modules\IdentitySync.Files.psm1') -Force

    # Keep the test output readable: the mocks' activity lines are only turned
    # on in the 'Activity output' tests below.
    Set-MockActivityOutput -Enabled $false

    $script:Token = 'test-token'

    # An existing Entra user, their manager, and a matching HRIS worker.
    function New-TestIdentity {
        param([string] $EmployeeId = 'E1042', [string] $Id = '00000000-0000-4000-8000-000000001042', [string] $Mail = 'alex.smith@example.com')
        [pscustomobject]@{
            id = $Id; employeeId = $EmployeeId; accountEnabled = $true
            givenName = 'Alex'; surname = 'Smith'; department = 'Quality'; managerEmployeeId = 'E1008'; mail = $Mail
        }
    }
    function New-TestManager {
        [pscustomobject]@{
            id = '00000000-0000-4000-8000-000000001008'; employeeId = 'E1008'; accountEnabled = $true
            givenName = 'Robin'; surname = 'Lee'; department = 'Quality'; managerEmployeeId = $null; mail = 'robin.lee@example.com'
        }
    }
    function New-TestWorker {
        param([string] $EmployeeId = 'E1042', [string] $Email)
        [pscustomobject]@{
            employeeId = $EmployeeId; status = 'Active'; firstName = 'Alex'; lastName = 'Smith'
            department = 'Quality'; managerEmployeeId = 'E1008'; startDate = '2026-11-02'; endDate = $null
            email = if ($Email) { $Email } else { $null }
        }
    }

    # Sets up the mocks with the given data and connects to both services, as
    # the sync will at the start of a run.
    function Initialize-TestServices {
        param(
            [object[]] $Identities = @((New-TestIdentity), (New-TestManager)),
            [object[]] $Workers = @(New-TestWorker),
            $Behaviour
        )
        Initialize-MockServices -Identities $Identities -Workers $Workers -Behaviour $Behaviour -HRISApiToken $Token
        Connect-MgGraph -Identity
        Connect-ExchangeOnline -ManagedIdentity -Organization 'example.onmicrosoft.com'
    }

    # Creates a new joiner the way the sync will, with New-MgUser.
    function New-TestJoiner {
        param([string] $EmployeeId = 'E2001', [string] $GivenName = 'Sam', [string] $Surname = 'Jones')
        New-MgUser -AccountEnabled -DisplayName "$GivenName $Surname" -GivenName $GivenName -Surname $Surname `
            -Department 'IT' -EmployeeId $EmployeeId -MailNickname "$GivenName.$Surname".ToLowerInvariant() `
            -UserPrincipalName "$EmployeeId@example.com" -PasswordProfile @{ Password = 'Temp-Passw0rd!'; ForceChangePasswordNextSignIn = $true }
    }

    # Calls Get-EXOMailbox the given number of times and returns each result:
    # the mailbox, or 'not found' while it is still provisioning.
    function Get-MailboxChecks {
        param([string] $Identity, [int] $Times)
        foreach ($i in 1..$Times) {
            try { Get-EXOMailbox -Identity $Identity }
            catch { 'not found' }
        }
    }

    # Runs a script block that should fail, and returns the HTTP status code it failed with.
    function Get-FailureStatus {
        param([scriptblock] $Call)
        try { & $Call | Out-Null; return 'no failure' }
        catch { return $_.Exception.Data['StatusCode'] }
    }

    # Runs a script block and returns the activity lines it printed, as text.
    # Write-Host writes to the information stream (6), so 6>&1 captures it.
    function Get-ActivityLines {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Used in the nested script block.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Failures are expected; only the printed lines are wanted.')]
        param([scriptblock] $Call)
        Set-MockActivityOutput -Enabled $true
        try { @(& { try { & $Call | Out-Null } catch { } } 6>&1 | ForEach-Object { "$_" }) -join "`n" }
        finally { Set-MockActivityOutput -Enabled $false }
    }
}

Describe 'Connecting' {
    It 'fails with 401 when Microsoft Graph is not connected' {
        Initialize-MockServices -Identities @(New-TestIdentity)
        Get-FailureStatus { Get-MgUser -Filter "employeeId eq 'E1042'" } | Should -Be 401
    }

    It 'fails with 401 when Exchange Online is not connected' {
        Initialize-MockServices -Identities @(New-TestIdentity)
        Connect-MgGraph -Identity
        Get-FailureStatus { Get-EXOMailbox -Identity 'alex.smith@example.com' } | Should -Be 401
    }

    It 'works once connected' {
        Initialize-TestServices
        @(Get-MgUser -Filter "employeeId eq 'E1042'") | Should -HaveCount 1
    }
}

Describe 'Get-MgUser' {
    BeforeEach { Initialize-TestServices }

    It 'finds users by employeeId with -Filter' {
        $user = Get-MgUser -Filter "employeeId eq 'E1042'"
        $user.Id | Should -Be '00000000-0000-4000-8000-000000001042'
    }

    It 'matches employeeId exactly, including case' {
        @(Get-MgUser -Filter "employeeId eq 'e1042'") | Should -HaveCount 0
    }

    It 'returns every match when the directory is ambiguous' {
        Initialize-TestServices -Identities @((New-TestIdentity), (New-TestIdentity -Id '00000000-0000-4000-8000-000000002042' -Mail 'alex.smith2@example.com'))
        @(Get-MgUser -Filter "employeeId eq 'E1042'") | Should -HaveCount 2
    }

    It 'returns the same property names as the real command' {
        $user = Get-MgUser -Filter "employeeId eq 'E1042'"
        foreach ($name in 'Id', 'DisplayName', 'GivenName', 'Surname', 'UserPrincipalName', 'Mail', 'EmployeeId', 'Department', 'AccountEnabled', 'Manager') {
            $user.PSObject.Properties.Name | Should -Contain $name
        }
    }

    It 'gets one user by -UserId' {
        (Get-MgUser -UserId '00000000-0000-4000-8000-000000001042').EmployeeId | Should -Be 'E1042'
    }

    It 'fails with 404 for an unknown -UserId' {
        Get-FailureStatus { Get-MgUser -UserId 'nope' } | Should -Be 404
    }

    It 'fills in the manager with -ExpandProperty manager' {
        $user = Get-MgUser -Filter "employeeId eq 'E1042'" -ExpandProperty manager
        $user.Manager.Id | Should -Be '00000000-0000-4000-8000-000000001008'
        $user.Manager.AdditionalProperties['employeeId'] | Should -Be 'E1008'
    }

    It 'leaves Manager empty without -ExpandProperty manager' {
        (Get-MgUser -Filter "employeeId eq 'E1042'").Manager | Should -BeNullOrEmpty
    }

    It 'rejects a filter the mock does not support with 400' {
        Get-FailureStatus { Get-MgUser -Filter "startsWith(displayName,'A')" } | Should -Be 400
    }

    It 'does not change the identities it was built from' {
        $identity = New-TestIdentity
        Initialize-TestServices -Identities @($identity, (New-TestManager))
        Update-MgUser -UserId $identity.id -Department 'Finance'
        $identity.department | Should -Be 'Quality'
    }
}

Describe 'New-MgUser' {
    BeforeEach { Initialize-TestServices }

    It 'creates a user with a new object ID and no Mail yet' {
        $user = New-TestJoiner

        $user.Id | Should -Not -BeNullOrEmpty
        $user.Mail | Should -BeNullOrEmpty
        $user.AccountEnabled | Should -BeTrue
        @(Get-MgUser -Filter "employeeId eq 'E2001'") | Should -HaveCount 1
    }

    It 'requires <Name>, as the real service does' -ForEach @(
        @{ Name = 'DisplayName' }, @{ Name = 'MailNickname' }, @{ Name = 'UserPrincipalName' }, @{ Name = 'PasswordProfile' }
    ) {
        $values = @{
            AccountEnabled = $true; DisplayName = 'Sam Jones'; EmployeeId = 'E2001'; MailNickname = 'sam.jones'
            UserPrincipalName = 'E2001@example.com'; PasswordProfile = @{ Password = 'Temp-Passw0rd!' }
        }
        $values.Remove($Name)
        Get-FailureStatus { New-MgUser -BodyParameter $values } | Should -Be 400
    }

    It 'refuses a userPrincipalName that is already taken' {
        New-TestJoiner | Out-Null
        Get-FailureStatus { New-TestJoiner } | Should -Be 400
    }

    It 'accepts the values in -BodyParameter' {
        $user = New-MgUser -BodyParameter @{
            AccountEnabled = $true; DisplayName = 'Sam Jones'; GivenName = 'Sam'; Surname = 'Jones'; EmployeeId = 'E2001'
            MailNickname = 'sam.jones'; UserPrincipalName = 'E2001@example.com'; PasswordProfile = @{ Password = 'Temp-Passw0rd!' }
        }
        $user.EmployeeId | Should -Be 'E2001'
    }
}

Describe 'Update-MgUser and Set-MgUserManagerByRef' {
    BeforeEach { Initialize-TestServices }

    It 'changes only the properties passed in' {
        Update-MgUser -UserId '00000000-0000-4000-8000-000000001042' -Department 'Finance'
        $user = Get-MgUser -UserId '00000000-0000-4000-8000-000000001042'

        $user.Department | Should -Be 'Finance'
        $user.GivenName | Should -Be 'Alex'
    }

    It 'disables an account with -AccountEnabled:$false' {
        Update-MgUser -UserId '00000000-0000-4000-8000-000000001042' -AccountEnabled:$false
        (Get-MgUser -UserId '00000000-0000-4000-8000-000000001042').AccountEnabled | Should -BeFalse
    }

    It 'returns nothing, like the real command' {
        Update-MgUser -UserId '00000000-0000-4000-8000-000000001042' -Department 'Finance' | Should -BeNullOrEmpty
    }

    It 'fails with 404 for an unknown user' {
        Get-FailureStatus { Update-MgUser -UserId 'nope' -Department 'IT' } | Should -Be 404
    }

    It 'sets the manager from an @odata.id reference' {
        $joiner = New-TestJoiner
        Set-MgUserManagerByRef -UserId $joiner.Id -BodyParameter @{ '@odata.id' = 'https://graph.microsoft.com/v1.0/users/00000000-0000-4000-8000-000000001008' }

        (Get-MgUser -UserId $joiner.Id -ExpandProperty manager).Manager.AdditionalProperties['employeeId'] | Should -Be 'E1008'
    }

    It 'fails with 404 when the manager does not exist' {
        Get-FailureStatus {
            Set-MgUserManagerByRef -UserId '00000000-0000-4000-8000-000000001042' -OdataId 'https://graph.microsoft.com/v1.0/users/nope'
        } | Should -Be 404
    }
}

Describe 'Get-EXOMailbox' {
    BeforeEach { Initialize-TestServices }

    It 'does not find a new mailbox until it is provisioned, then returns its address' {
        $user   = New-TestJoiner
        $checks = @(Get-MailboxChecks -Identity $user.Id -Times 2)

        $checks[0] | Should -Be 'not found'
        $checks[1].PrimarySmtpAddress | Should -Be 'sam.jones@example.com'
    }

    It 'fails with 404 while the mailbox is provisioning, as the real command does' {
        $user = New-TestJoiner
        Get-FailureStatus { Get-EXOMailbox -Identity $user.Id } | Should -Be 404
    }

    It 'sets the user''s Mail once the mailbox is provisioned' {
        $user = New-TestJoiner
        Get-MailboxChecks -Identity $user.Id -Times 2 | Out-Null
        (Get-MgUser -UserId $user.Id).Mail | Should -Be 'sam.jones@example.com'
    }

    It 'follows readyAfterChecks from the behaviour settings' {
        Initialize-TestServices -Behaviour ([pscustomobject]@{ exchange = [pscustomobject]@{ readyAfterChecks = 4 } })
        $user    = New-TestJoiner
        $results = Get-MailboxChecks -Identity $user.Id -Times 4 | ForEach-Object { if ($_ -is [string]) { $_ } else { 'found' } }

        $results | Should -Be @('not found', 'not found', 'not found', 'found')
    }

    It 'never finds a mailbox listed in neverReady' {
        Initialize-TestServices -Behaviour ([pscustomobject]@{ exchange = [pscustomobject]@{ neverReady = @('E2001') } })
        $user = New-TestJoiner
        Get-MailboxChecks -Identity $user.Id -Times 10 | Should -Be (@('not found') * 10)
    }

    It 'assigns a different address when the requested one is taken' {
        $first  = New-TestJoiner -EmployeeId 'E2001'
        $second = New-TestJoiner -EmployeeId 'E2002'
        $addresses = foreach ($user in $first, $second) {
            (Get-MailboxChecks -Identity $user.Id -Times 2)[-1].PrimarySmtpAddress
        }
        $addresses | Should -Be @('sam.jones@example.com', 'sam.jones2@example.com')
    }

    It 'finds an existing user''s mailbox straight away, by email or object ID' {
        (Get-EXOMailbox -Identity 'alex.smith@example.com').PrimarySmtpAddress | Should -Be 'alex.smith@example.com'
        (Get-EXOMailbox -Identity '00000000-0000-4000-8000-000000001042').PrimarySmtpAddress | Should -Be 'alex.smith@example.com'
    }

    It 'fails with 404 for a user that does not exist' {
        Get-FailureStatus { Get-EXOMailbox -Identity 'nobody@example.com' } | Should -Be 404
    }
}

Describe 'Simulated failures' {
    It 'fails every call when times is always' {
        Initialize-TestServices -Behaviour ([pscustomobject]@{ entra = [pscustomobject]@{ failures = [pscustomobject]@{ E1042 = [pscustomobject]@{ statusCode = 503; times = 'always' } } } })
        1..5 | ForEach-Object { Get-FailureStatus { Get-MgUser -Filter "employeeId eq 'E1042'" } } | Should -Be @(503, 503, 503, 503, 503)
    }

    It 'fails the first N calls, then succeeds' {
        Initialize-TestServices -Behaviour ([pscustomobject]@{ entra = [pscustomobject]@{ failures = [pscustomobject]@{ E1042 = [pscustomobject]@{ statusCode = 429; times = 2 } } } })

        Get-FailureStatus { Get-MgUser -Filter "employeeId eq 'E1042'" } | Should -Be 429
        Get-FailureStatus { Get-MgUser -Filter "employeeId eq 'E1042'" } | Should -Be 429
        @(Get-MgUser -Filter "employeeId eq 'E1042'") | Should -HaveCount 1
    }

    It 'includes Retry-After on a 429' {
        Initialize-TestServices -Behaviour ([pscustomobject]@{ entra = [pscustomobject]@{ failures = [pscustomobject]@{ E1042 = [pscustomobject]@{ statusCode = 429; times = 1 } } } })
        try { Get-MgUser -Filter "employeeId eq 'E1042'"; $retryAfter = $null }
        catch { $retryAfter = $_.Exception.Data['RetryAfterSeconds'] }
        $retryAfter | Should -BeGreaterThan 0
    }

    It 'does not fail other employeeIds' {
        Initialize-TestServices -Behaviour ([pscustomobject]@{ entra = [pscustomobject]@{ failures = [pscustomobject]@{ E9999 = [pscustomobject]@{ statusCode = 503; times = 'always' } } } })
        @(Get-MgUser -Filter "employeeId eq 'E1042'") | Should -HaveCount 1
    }
}

Describe 'HRIS write-back API' {
    BeforeEach { Initialize-TestServices }

    Context 'Authentication boundary' {
        It 'rejects a call with no token' {
            Get-FailureStatus { Get-HRISWorker -EmployeeId 'E1042' } | Should -Be 401
        }

        It 'rejects a write with the wrong token before looking at anything else' {
            Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'not-valid' -Email 'x' -IdempotencyKey 'k' -Token 'wrong' } | Should -Be 401
        }

        It 'never includes the token in the error message' {
            try { Get-HRISWorker -EmployeeId 'E1042' -Token 'secret-guess'; $message = '' }
            catch { $message = $_.Exception.Message }

            $message | Should -Not -Match 'secret-guess'
            $message | Should -Not -Match $Token
        }
    }

    Context 'Validation' {
        It 'rejects a malformed <Name>' -ForEach @(
            @{ Name = 'employeeId'; EmployeeId = 'e1042'; Email = 'alex.smith@example.com'; Key = 'k' }
            @{ Name = 'email';      EmployeeId = 'E1042'; Email = 'not-an-email';           Key = 'k' }
            @{ Name = 'key';        EmployeeId = 'E1042'; Email = 'alex.smith@example.com'; Key = '' }
        ) {
            Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId $EmployeeId -Email $Email -IdempotencyKey $Key -Token $Token } | Should -Be 400
        }

        It 'fails with 404 for an unknown employeeId' {
            Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'E2000' -Email 'a@example.com' -IdempotencyKey 'k' -Token $Token } | Should -Be 404
        }

        It 'fails with 409 when more than one worker has the employeeId' {
            Initialize-TestServices -Workers @((New-TestWorker), (New-TestWorker))
            Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'a@example.com' -IdempotencyKey 'k' -Token $Token } | Should -Be 409
        }
    }

    Context 'Write-back rules' {
        It 'writes the address when the worker has none' {
            $result = Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token

            $result.Result | Should -Be 'Updated'
            (Get-HRISWorker -EmployeeId 'E1042' -Token $Token).email | Should -Be 'alex.smith@example.com'
        }

        It 'returns NoChange when the worker already has the same address' {
            Initialize-TestServices -Workers @(New-TestWorker -Email 'alex.smith@example.com')
            (Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token).Result | Should -Be 'NoChange'
        }

        It 'refuses to overwrite a different address with 409' {
            Initialize-TestServices -Workers @(New-TestWorker -Email 'old.address@example.com')

            Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token } | Should -Be 409
            (Get-HRISWorker -EmployeeId 'E1042' -Token $Token).email | Should -Be 'old.address@example.com'
        }

        It 'does not change the workers it was built from' {
            $worker = New-TestWorker
            Initialize-TestServices -Workers @($worker)
            Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token | Out-Null

            $worker.email | Should -BeNullOrEmpty
        }
    }

    Context 'Idempotency' {
        It 'returns the first result again when the same request is replayed' {
            $first  = Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token
            $second = Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token

            $first.Result | Should -Be 'Updated'
            $second.Result | Should -Be 'Updated'
            $second.Replayed | Should -BeTrue
        }

        It 'rejects a reused key for a different request with 422' {
            Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token | Out-Null
            Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'other@example.com' -IdempotencyKey 'k1' -Token $Token } | Should -Be 422
        }
    }
}

Describe 'Activity output' {
    BeforeEach { Initialize-TestServices }

    It 'says when a user is created and its mailbox starts provisioning' {
        $lines = Get-ActivityLines { New-TestJoiner }

        $lines | Should -Match '\[Entra mock\]\s+Created user E2001 Sam Jones'
        $lines | Should -Match '\[Exchange mock\]\s+Mailbox provisioning started for E2001'
    }

    It 'says when a mailbox is still provisioning, and when it is found' {
        $user  = New-TestJoiner
        $lines = Get-ActivityLines { Get-MailboxChecks -Identity $user.Id -Times 2 }

        $lines | Should -Match 'not found yet; still provisioning \(check 1 of 2\)'
        $lines | Should -Match 'now provisioned: sam.jones@example.com'
    }

    It 'shows a failed call with its HTTP status' {
        $lines = Get-ActivityLines { Get-HRISWorker -EmployeeId 'E1042' -Token 'wrong' }
        $lines | Should -Match '\[HRIS mock\]\s+HTTP 401'
    }

    It 'never prints the password or the API token' {
        $lines = Get-ActivityLines {
            New-TestJoiner
            Set-HRISWorkerEmail -EmployeeId 'E1042' -Email 'alex.smith@example.com' -IdempotencyKey 'k1' -Token $Token
            Get-HRISWorker -EmployeeId 'E1042' -Token 'secret-guess'
        }

        $lines | Should -Not -BeNullOrEmpty
        $lines | Should -Not -Match 'Temp-Passw0rd'
        $lines | Should -Not -Match $Token
        $lines | Should -Not -Match 'secret-guess'
    }

    It 'prints nothing when activity output is turned off' {
        @(& { New-TestJoiner | Out-Null } 6>&1) | Should -HaveCount 0
    }
}

Describe 'Configured test cases in the mock files' {
    BeforeAll {
        $mocks = Join-Path $PSScriptRoot '..\IdentitySync\Mocks'
        $script:Behaviour  = Get-Content (Join-Path $mocks 'mock-behaviour.json') -Raw | ConvertFrom-Json
        $script:Identities = Read-JsonArray -Path (Join-Path $mocks 'Entra-Identities.json')
        $script:Workers    = Read-JsonArray -Path (Join-Path $mocks 'HRIS-Workers.json')
    }
    BeforeEach { Initialize-TestServices -Identities $Identities -Workers $Workers -Behaviour $Behaviour }

    It 'E9011 (transient failure): every Graph call fails with 503' {
        1..5 | ForEach-Object { Get-FailureStatus { Get-MgUser -Filter "employeeId eq 'E9011'" } } | Should -Be @(503, 503, 503, 503, 503)
    }

    It 'E9012 (mailbox not ready): the mailbox is never found' {
        $user = New-TestJoiner -EmployeeId 'E9012' -GivenName 'Rowan' -Surname 'Brown'
        Get-MailboxChecks -Identity $user.Id -Times 10 | Should -Be (@('not found') * 10)
    }

    It 'E9013 and E9014 (same name): E9014 is assigned alex.clarke2@example.com' {
        $addresses = foreach ($id in 'E9013', 'E9014') {
            $user = New-TestJoiner -EmployeeId $id -GivenName 'Alex' -Surname 'Clarke'
            (Get-MailboxChecks -Identity $user.Id -Times 2)[-1].PrimarySmtpAddress
        }
        $addresses | Should -Be @('alex.clarke@example.com', 'alex.clarke2@example.com')
    }

    It 'E9015 (write-back failure): every HRIS write fails with 503' {
        Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'E9015' -Email 'jordan.wilson@example.com' -IdempotencyKey 'k1' -Token $Token } | Should -Be 503
    }

    It 'E9016 (existing same email): the write-back returns NoChange' {
        (Set-HRISWorkerEmail -EmployeeId 'E9016' -Email 'morgan.wright@example.com' -IdempotencyKey 'k1' -Token $Token).Result | Should -Be 'NoChange'
    }

    It 'E9017 (conflicting email): the write-back is refused with 409' {
        Get-FailureStatus { Set-HRISWorkerEmail -EmployeeId 'E9017' -Email 'quinn.hall@example.com' -IdempotencyKey 'k1' -Token $Token } | Should -Be 409
    }
}
