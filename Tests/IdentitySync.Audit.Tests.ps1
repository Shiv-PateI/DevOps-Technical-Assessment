<#
.SYNOPSIS
    Pester tests for the structured audit log.

.DESCRIPTION
    The first part tests the audit functions directly. The second part runs
    Invoke-IdentitySync.ps1 end to end, once with -Apply and once as a dry
    run, into temporary folders, and checks the audit file each produces:
    one Worker line per employeeId, one correlation ID per run, the fields
    the brief asks for, and no secrets or personal details beyond the
    employeeId.

    Run from the repository root with:
        Invoke-Pester ./Tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\IdentitySync\Modules\IdentitySync.Audit.psm1') -Force

    # Reads an audit file back as objects, one per line.
    function Read-AuditFile {
        param([string] $Path)
        Get-Content -Path $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
    }

    # A decision as Get-IdentityPlan returns it, with the parts the audit reads.
    function New-TestDecision {
        param([string] $EmployeeId = 'E2001', [string] $Action = 'Create', [object[]] $Identities = @())
        [pscustomobject]@{
            EmployeeId      = $EmployeeId
            Name            = 'Sam Jones'
            Action          = $Action
            Reason          = 'New joiner with no existing identity'
            Changes         = [ordered]@{ department = [pscustomobject]@{ From = $null; To = 'IT' } }
            HRISRecords     = @([pscustomobject]@{ employeeId = $EmployeeId; firstName = 'Sam'; lastName = 'Jones' })
            EntraIdentities = $Identities
        }
    }

    $script:Folder = Join-Path ([System.IO.Path]::GetTempPath()) ('identitysync-audit-' + [guid]::NewGuid())
}

AfterAll {
    if (Test-Path $Folder) { Remove-Item $Folder -Recurse -Force }
}

Describe 'New-AuditLog' {
    It 'names the file by UTC time and the start of the correlation ID, and creates the folder' {
        $log = New-AuditLog -Folder (Join-Path $Folder 'unit')

        Split-Path $log.Path -Leaf | Should -Match "^audit-\d{8}T\d{6}Z-$($log.CorrelationId.Substring(0, 8))\.jsonl$"
        Test-Path (Join-Path $Folder 'unit') | Should -BeTrue
    }

    It 'gives each run a new GUID as its correlation ID' {
        $first  = New-AuditLog -Folder (Join-Path $Folder 'unit')
        $second = New-AuditLog -Folder (Join-Path $Folder 'unit')

        { [guid]::Parse($first.CorrelationId) } | Should -Not -Throw
        $first.CorrelationId | Should -Not -Be $second.CorrelationId
    }

    It 'marks the run as DryRun or Apply' {
        (New-AuditLog -Folder (Join-Path $Folder 'unit') -DryRun).Mode | Should -Be 'DryRun'
        (New-AuditLog -Folder (Join-Path $Folder 'unit')).Mode | Should -Be 'Apply'
    }
}

Describe 'ConvertTo-AuditEntry' {
    BeforeAll {
        $script:ApplyLog = New-AuditLog -Folder (Join-Path $Folder 'unit')
        $script:DryLog   = New-AuditLog -Folder (Join-Path $Folder 'unit') -DryRun
    }

    It 'has every field the brief asks for' {
        $entry = ConvertTo-AuditEntry -Log $ApplyLog -Decision (New-TestDecision)
        foreach ($field in 'timestamp', 'correlationId', 'employeeId', 'proposedAction', 'reason', 'result',
                           'entraObjectId', 'primarySmtpAddress', 'writeBackResult') {
            $entry.Contains($field) | Should -BeTrue -Because "$field is required"
        }
    }

    It 'marks every worker on a dry run as Proposed' {
        (ConvertTo-AuditEntry -Log $DryLog -Decision (New-TestDecision)).result | Should -Be 'Proposed'
    }

    It 'takes the stage, object ID, address and write-back result from the stages and state' {
        $stages = [pscustomobject]@{ Stage = 'Complete'; Outcome = 'Updated'; Reason = 'Wrote sam.jones@example.com to the HRIS' }
        $entry  = [pscustomobject]@{ entraObjectId = 'obj-1'; primarySmtpAddress = 'sam.jones@example.com'; writeBackResult = 'Updated' }
        $line   = ConvertTo-AuditEntry -Log $ApplyLog -Decision (New-TestDecision) -Stages $stages -StateEntry $entry -RetryCount 2

        $line.result | Should -Be 'Updated'
        $line.stage | Should -Be 'Complete'
        $line.entraObjectId | Should -Be 'obj-1'
        $line.primarySmtpAddress | Should -Be 'sam.jones@example.com'
        $line.writeBackResult | Should -Be 'Updated'
        $line.retryCount | Should -Be 2
    }

    It 'takes the object ID from the matched identity when there is no state entry' {
        $decision = New-TestDecision -Action 'Disable' -Identities @([pscustomobject]@{ id = 'obj-9' })
        $change   = [pscustomobject]@{ Stage = 'Disable'; Outcome = 'Done'; Reason = 'Account disabled' }
        $line     = ConvertTo-AuditEntry -Log $ApplyLog -Decision $decision -Change $change

        $line.entraObjectId | Should -Be 'obj-9'
        $line.result | Should -Be 'Done'
        $line.changeResult | Should -Be 'Done'
    }

    It 'records NothingDone when neither a change nor the stages ran' {
        (ConvertTo-AuditEntry -Log $ApplyLog -Decision (New-TestDecision -Action 'ManualReview')).result | Should -Be 'NothingDone'
    }

    It 'does not copy the HRIS record into the line' {
        $line = ConvertTo-AuditEntry -Log $ApplyLog -Decision (New-TestDecision)
        $json = ConvertTo-Json -InputObject $line -Compress
        $json | Should -Not -Match 'firstName|lastName|Sam|Jones'
    }
}

Describe 'Write-AuditEntry' {
    It 'appends one compact JSON line per entry' {
        $log = New-AuditLog -Folder (Join-Path $Folder 'unit')
        Write-AuditEntry -Log $log -Entry ([ordered]@{ event = 'One' })
        Write-AuditEntry -Log $log -Entry ([ordered]@{ event = 'Two' })

        $lines = @(Get-Content $log.Path)
        $lines | Should -HaveCount 2
        ($lines[1] | ConvertFrom-Json).event | Should -Be 'Two'
    }
}

Describe 'Audit log from a full run' {
    BeforeAll {
        $script:Sync = Join-Path $PSScriptRoot '..\IdentitySync\Scripts\Invoke-IdentitySync.ps1'

        # Runs the sync into temporary folders, without printing, and returns the audit lines.
        function Invoke-AuditedRun {
            param([string] $Name, [switch] $Apply)
            $state   = Join-Path $Folder "$Name-state"
            $reports = Join-Path $Folder "$Name-reports"
            & $Sync -Apply:$Apply -StatePath $state -ReportsPath $reports -Today '2026-11-04' 6>$null | Out-Null
            $file = @(Get-ChildItem -Path $reports -Filter 'audit-*.jsonl')
            $file | Should -HaveCount 1
            [pscustomobject]@{ Path = $file[0].FullName; Lines = @(Read-AuditFile $file[0].FullName) }
        }

        $script:Applied = Invoke-AuditedRun -Name 'apply' -Apply
        $script:DryRun  = Invoke-AuditedRun -Name 'dry'
        $script:Workers = @($Applied.Lines | Where-Object event -eq 'Worker')

        # The Worker line for one employeeId.
        function Get-WorkerLine { param([string] $EmployeeId) @($Workers | Where-Object employeeId -eq $EmployeeId)[0] }
    }

    It 'starts with RunStarted and ends with RunCompleted' {
        $Applied.Lines[0].event | Should -Be 'RunStarted'
        $Applied.Lines[-1].event | Should -Be 'RunCompleted'
    }

    It 'uses one correlation ID, a GUID, on every line' {
        $ids = @($Applied.Lines.correlationId | Select-Object -Unique)
        $ids | Should -HaveCount 1
        { [guid]::Parse($ids[0]) } | Should -Not -Throw
    }

    It 'writes exactly one Worker line per employeeId decided (23)' {
        $Workers | Should -HaveCount 23
        @($Workers | Where-Object employeeId | Group-Object employeeId | Where-Object Count -gt 1) | Should -HaveCount 0
    }

    It 'records the successful write-back with the assigned address (E9014)' {
        $line = Get-WorkerLine 'E9014'
        $line.proposedAction | Should -Be 'Create'
        $line.stage | Should -Be 'Complete'
        $line.primarySmtpAddress | Should -Be 'alex.clarke2@example.com'
        $line.writeBackResult | Should -Be 'Updated'
        $line.entraObjectId | Should -Not -BeNullOrEmpty
    }

    It 'records the transient failure and its retries (E9011)' {
        $line = Get-WorkerLine 'E9011'
        $line.stage | Should -Be 'IdentityFailed'
        $line.retryCount | Should -Be 3
        $line.stageReason | Should -Match 'gave up after 4 attempts'
    }

    It 'records the conflicting email as ManualReview (E9017)' {
        $line = Get-WorkerLine 'E9017'
        $line.stage | Should -Be 'ManualReview'
        $line.result | Should -Be 'Stopped'
    }

    It 'records the disable with the Entra object ID (E9004)' {
        $line = Get-WorkerLine 'E9004'
        $line.proposedAction | Should -Be 'Disable'
        $line.changeResult | Should -Be 'Done'
        $line.entraObjectId | Should -Be '00000000-0000-4000-8000-000000009004'
    }

    It 'records a record with no employeeId, so it is not lost' {
        @($Workers | Where-Object { -not $_.employeeId }) | Should -HaveCount 1
    }

    It 'records the identity with no HRIS record as left unchanged (E8001)' {
        $line = @($Applied.Lines | Where-Object event -eq 'IdentityNotInHRIS')
        $line | Should -HaveCount 1
        $line[0].employeeId | Should -Be 'E8001'
        $line[0].result | Should -Be 'LeftUnchanged'
    }

    It 'counts each action in RunCompleted' {
        $summary = $Applied.Lines[-1]
        $summary.workerCount | Should -Be 23
        $summary.actions.Create | Should -Be 7
        $summary.actions.ManualReview | Should -Be 7
    }

    It 'contains no passwords, tokens or names' {
        $text = Get-Content $Applied.Path -Raw
        $text | Should -Not -Match '(?i)password'
        $text | Should -Not -Match 'mock-hris-token'
        $text | Should -Not -Match '"firstName"|"lastName"|Jordan Brown'
    }

    It 'marks a dry run as DryRun, with every worker Proposed and no stages' {
        @($DryRun.Lines.mode | Select-Object -Unique) | Should -Be @('DryRun')
        $dryWorkers = @($DryRun.Lines | Where-Object event -eq 'Worker')
        $dryWorkers | Should -HaveCount 23
        @($dryWorkers.result | Select-Object -Unique) | Should -Be @('Proposed')
        @($dryWorkers | Where-Object stage) | Should -HaveCount 0
    }
}
