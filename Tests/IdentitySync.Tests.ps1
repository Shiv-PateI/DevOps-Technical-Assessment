<#
.SYNOPSIS
    Pester tests for the identity sync validation and decision logic.

.DESCRIPTION
    Each test builds a small worker record (and Entra identity where needed)
    inline, so the condition being tested is visible in the test itself.
    Tests use a fixed "today" so date rules give the same result on any day.

    Run from the repository root with:
        Invoke-Pester ./Tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\IdentitySync\Modules\IdentitySync.psm1') -Force

    # Fixed date used as "today" in every test.
    $script:Today = [datetime] '2026-11-04'

    # Builds a valid active worker. -Set overrides fields; -Remove drops them entirely.
    function New-TestWorker {
        param([hashtable] $Set = @{}, [string[]] $Remove = @())

        $worker = [ordered]@{
            employeeId        = 'E1042'
            status            = 'Active'
            firstName         = 'Alex'
            lastName          = 'Smith'
            department        = 'Quality'
            managerEmployeeId = 'E1008'
            startDate         = '2026-11-02'
            endDate           = $null
            email             = $null
        }
        foreach ($key in $Set.Keys) { $worker[$key] = $Set[$key] }
        foreach ($key in $Remove)   { $worker.Remove($key) }
        [pscustomobject] $worker
    }

    # Builds an enabled Entra identity that matches the default test worker.
    function New-TestIdentity {
        param([hashtable] $Set = @{})

        $identity = [ordered]@{
            id                = '00000000-0000-4000-8000-000000001042'
            employeeId        = 'E1042'
            accountEnabled    = $true
            givenName         = 'Alex'
            surname           = 'Smith'
            department        = 'Quality'
            managerEmployeeId = 'E1008'
        }
        foreach ($key in $Set.Keys) { $identity[$key] = $Set[$key] }
        [pscustomobject] $identity
    }
}

Describe 'Test-WorkerRecord' {
    It 'accepts a valid record' {
        @(Test-WorkerRecord -Worker (New-TestWorker)) | Should -HaveCount 0
    }

    It 'rejects a record with no employeeId field' {
        Test-WorkerRecord -Worker (New-TestWorker -Remove 'employeeId') |
            Should -Contain "Missing required field 'employeeId'"
    }

    It 'rejects a blank employeeId' {
        Test-WorkerRecord -Worker (New-TestWorker -Set @{ employeeId = '  ' }) |
            Should -Contain "Missing required field 'employeeId'"
    }

    It 'rejects an employeeId in the wrong format: <Value>' -ForEach @(
        @{ Value = '1042' }, @{ Value = 'e1042' }, @{ Value = 'E10A2' }
    ) {
        (Test-WorkerRecord -Worker (New-TestWorker -Set @{ employeeId = $Value })) -join ' ' |
            Should -Match 'not in the expected format'
    }

    It 'rejects a malformed status: <Value>' -ForEach @(
        @{ Value = 'Actve' }, @{ Value = 'active' }, @{ Value = 'Left' }
    ) {
        (Test-WorkerRecord -Worker (New-TestWorker -Set @{ status = $Value })) -join ' ' |
            Should -Match "status '$Value' is not one of"
    }

    It 'rejects a date that is not yyyy-MM-dd: <Value>' -ForEach @(
        @{ Value = '14/11/2026' }, @{ Value = '2026-02-30' }, @{ Value = '2026-11-4' }, @{ Value = 'soon' }
    ) {
        (Test-WorkerRecord -Worker (New-TestWorker -Set @{ startDate = $Value })) -join ' ' |
            Should -Match "startDate '$Value' is not a valid yyyy-MM-dd date"
    }

    It 'rejects an end date before the start date' {
        $worker = New-TestWorker -Set @{ status = 'Inactive'; startDate = '2026-10-20'; endDate = '2026-10-10' }
        Test-WorkerRecord -Worker $worker | Should -Contain 'endDate 2026-10-10 is before startDate 2026-10-20'
    }

    It 'rejects an Inactive worker with no end date' {
        Test-WorkerRecord -Worker (New-TestWorker -Set @{ status = 'Inactive' }) |
            Should -Contain 'status is Inactive but endDate is missing'
    }

    It 'rejects a worker who is their own manager' {
        Test-WorkerRecord -Worker (New-TestWorker -Set @{ managerEmployeeId = 'E1042' }) |
            Should -Contain 'managerEmployeeId is the worker themself'
    }

    It 'reports every problem, not just the first' {
        $worker = New-TestWorker -Set @{ status = 'Actve'; startDate = '14/11/2026' } -Remove 'lastName'
        @(Test-WorkerRecord -Worker $worker) | Should -HaveCount 3
    }
}

Describe 'Get-IdentityDecision' {
    Context 'New joiner' {
        It 'creates an enabled identity when the start date has arrived' {
            $decision = Get-IdentityDecision -Worker (New-TestWorker) -Identities @() -Today $Today

            $decision.Action | Should -Be 'Create'
            $decision.Changes['accountEnabled'].To | Should -BeTrue
            $decision.Changes['department'].To | Should -Be 'Quality'
        }

        It 'sets the first and last name on a new identity' {
            $decision = Get-IdentityDecision -Worker (New-TestWorker) -Identities @() -Today $Today

            $decision.Changes['givenName'].To | Should -Be 'Alex'
            $decision.Changes['surname'].To | Should -Be 'Smith'
        }

        It 'creates a disabled identity when the start date is in the future' {
            $worker   = New-TestWorker -Set @{ startDate = '2026-11-18' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @() -Today $Today

            $decision.Action | Should -Be 'Create'
            $decision.Changes['accountEnabled'].To | Should -BeFalse
            $decision.Reason | Should -Match 'disabled until the start date'
        }

        It 'enables a staged identity once the start date arrives' {
            $identity = New-TestIdentity -Set @{ accountEnabled = $false }
            $decision = Get-IdentityDecision -Worker (New-TestWorker) -Identities @($identity) -Today $Today

            $decision.Action | Should -Be 'Update'
            @($decision.Changes.Keys) | Should -Be @('accountEnabled')
        }

        It 'leaves a staged identity disabled before the start date' {
            $worker   = New-TestWorker -Set @{ startDate = '2026-11-18' }
            $identity = New-TestIdentity -Set @{ accountEnabled = $false }
            $decision = Get-IdentityDecision -Worker $worker -Identities @($identity) -Today $Today

            $decision.Action | Should -Be 'NoChange'
        }
    }

    Context 'Mover' {
        It 'updates only the attributes that changed' {
            $worker   = New-TestWorker -Set @{ department = 'Finance'; managerEmployeeId = 'E1003' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today

            $decision.Action | Should -Be 'Update'
            @($decision.Changes.Keys) | Should -Be @('department', 'managerEmployeeId')
            $decision.Changes['department'].From | Should -Be 'Quality'
            $decision.Changes['department'].To | Should -Be 'Finance'
        }

        It 'returns NoChange when the identity already matches' {
            $decision = Get-IdentityDecision -Worker (New-TestWorker) -Identities @(New-TestIdentity) -Today $Today
            $decision.Action | Should -Be 'NoChange'
        }

        It 'does not update a first or last name that differs from Entra' {
            $worker   = New-TestWorker -Set @{ firstName = 'Sam'; lastName = 'Jones' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today

            $decision.Action | Should -Be 'NoChange'
            $decision.Changes.Count | Should -Be 0
        }

        It 'updates only the department when the name and department both differ' {
            $worker   = New-TestWorker -Set @{ lastName = 'Jones'; department = 'Finance' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today

            $decision.Action | Should -Be 'Update'
            @($decision.Changes.Keys) | Should -Be @('department')
        }

        It 'treats a null value and an empty string as the same' {
            $worker   = New-TestWorker -Set @{ managerEmployeeId = $null }
            $identity = New-TestIdentity -Set @{ managerEmployeeId = '' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @($identity) -Today $Today

            $decision.Action | Should -Be 'NoChange'
        }
    }

    Context 'Leaver' {
        BeforeAll {
            $script:leaver = New-TestWorker -Set @{ status = 'Inactive'; startDate = '2026-01-05'; endDate = '2026-11-01' }
        }

        It 'disables an enabled identity when status is Inactive and the end date has passed' {
            $decision = Get-IdentityDecision -Worker $leaver -Identities @(New-TestIdentity) -Today $Today

            $decision.Action | Should -Be 'Disable'
            $decision.Changes['accountEnabled'].To | Should -BeFalse
        }

        It 'disables on the end date itself' {
            $worker   = New-TestWorker -Set @{ status = 'Inactive'; startDate = '2026-01-05'; endDate = '2026-11-04' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today
            $decision.Action | Should -Be 'Disable'
        }

        It 'returns NoChange when the identity is already disabled' {
            $identity = New-TestIdentity -Set @{ accountEnabled = $false }
            $decision = Get-IdentityDecision -Worker $leaver -Identities @($identity) -Today $Today
            $decision.Action | Should -Be 'NoChange'
        }

        It 'returns NoChange when no identity exists' {
            $decision = Get-IdentityDecision -Worker $leaver -Identities @() -Today $Today
            $decision.Action | Should -Be 'NoChange'
        }

        It 'never disables an Inactive worker whose end date is still in the future' {
            $worker   = New-TestWorker -Set @{ status = 'Inactive'; startDate = '2026-01-05'; endDate = '2026-12-01' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today
            $decision.Action | Should -Be 'ManualReview'
        }

        It 'never disables an Active worker whose end date has passed' {
            $worker   = New-TestWorker -Set @{ startDate = '2026-01-05'; endDate = '2026-11-01' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today
            $decision.Action | Should -Be 'ManualReview'
        }
    }

    Context 'Records that cannot be handled safely' {
        It 'sends an invalid record to ManualReview with the validation reason' {
            $worker   = New-TestWorker -Set @{ status = 'Actve' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @() -Today $Today

            $decision.Action | Should -Be 'ManualReview'
            $decision.Reason | Should -Match "Record failed validation: status 'Actve'"
        }

        It 'sends an invalid record to ManualReview even when an identity exists' {
            $worker   = New-TestWorker -Set @{ status = 'Inactive'; endDate = 'yesterday' }
            $decision = Get-IdentityDecision -Worker $worker -Identities @(New-TestIdentity) -Today $Today
            $decision.Action | Should -Be 'ManualReview'
        }

        It 'sends an ambiguous match to ManualReview instead of picking an identity' {
            $second   = New-TestIdentity -Set @{ id = '00000000-0000-4000-8000-000000002042' }
            $decision = Get-IdentityDecision -Worker (New-TestWorker) -Identities @((New-TestIdentity), $second) -Today $Today

            $decision.Action | Should -Be 'ManualReview'
            $decision.Reason | Should -Match '2 Entra identities have employeeId E1042'
        }
    }
}

Describe 'Get-IdentityPlan' {
    It 'matches identities by employeeId, not by name' {
        # Same name as the worker, different employeeId: must not be treated as theirs.
        $namesake = New-TestIdentity -Set @{ employeeId = 'E2000' }
        $decision = @(Get-IdentityPlan -Workers @(New-TestWorker) -Identities @($namesake) -Today $Today)

        $decision | Should -HaveCount 1
        $decision[0].Action | Should -Be 'Create'
    }

    It 'treats identical duplicate records as one, so there is no duplicate action' {
        $plan = @(Get-IdentityPlan -Workers @((New-TestWorker), (New-TestWorker)) -Today $Today)

        $plan | Should -HaveCount 1
        $plan[0].Action | Should -Be 'Create'
        $plan[0].Reason | Should -Match '2 identical records'
    }

    It 'sends duplicate records that disagree to ManualReview' {
        $first  = New-TestWorker -Set @{ department = 'Care' }
        $second = New-TestWorker -Set @{ department = 'Quality' }
        $plan   = @(Get-IdentityPlan -Workers @($first, $second) -Today $Today)

        $plan | Should -HaveCount 1
        $plan[0].Action | Should -Be 'ManualReview'
        $plan[0].Reason | Should -Match 'disagree'
    }

    It 'does not merge employeeIds that differ only by case' {
        $upper = New-TestWorker
        $lower = New-TestWorker -Set @{ employeeId = 'e1042' }
        $plan  = @(Get-IdentityPlan -Workers @($upper, $lower) -Today $Today)

        $plan | Should -HaveCount 2
        $plan[1].Action | Should -Be 'ManualReview'
    }

    It 'decides each record without an employeeId on its own' {
        $first  = New-TestWorker -Remove 'employeeId'
        $second = New-TestWorker -Remove 'employeeId' -Set @{ firstName = 'Sam' }
        $plan   = @(Get-IdentityPlan -Workers @($first, $second) -Today $Today)

        $plan | Should -HaveCount 2
        $plan | ForEach-Object { $_.Action | Should -Be 'ManualReview' }
    }

    It 'gives the same decisions when the same input is planned twice' {
        $workers    = @((New-TestWorker), (New-TestWorker -Set @{ employeeId = 'E1043'; department = 'IT' }))
        $identities = @(New-TestIdentity)

        $first  = Get-IdentityPlan -Workers $workers -Identities $identities -Today $Today | ForEach-Object { "$($_.EmployeeId):$($_.Action)" }
        $second = Get-IdentityPlan -Workers $workers -Identities $identities -Today $Today | ForEach-Object { "$($_.EmployeeId):$($_.Action)" }

        $second | Should -Be $first
    }

    It 'makes no decision for an identity that is missing from the input' {
        $absent = New-TestIdentity -Set @{ employeeId = 'E3000' }
        $plan   = @(Get-IdentityPlan -Workers @(New-TestWorker) -Identities @((New-TestIdentity), $absent) -Today $Today)

        $plan.EmployeeId | Should -Not -Contain 'E3000'
        $plan.Action | Should -Not -Contain 'Disable'
    }
}

Describe 'Get-UnmatchedIdentity' {
    It 'returns identities that have no HRIS record' {
        $absent    = New-TestIdentity -Set @{ employeeId = 'E3000' }
        $unmatched = @(Get-UnmatchedIdentity -Workers @(New-TestWorker) -Identities @((New-TestIdentity), $absent))

        $unmatched | Should -HaveCount 1
        $unmatched[0].employeeId | Should -Be 'E3000'
    }
}
