<#
.SYNOPSIS
    Pester tests for Invoke-WithRetry: bounded retry with exponential back-off.

.DESCRIPTION
    Each test uses a script block that fails a set number of times with a
    chosen HTTP status, and a stub in place of Start-Sleep that records the
    waits instead of sleeping, so the tests are fast and the back-off can be
    checked exactly.

    Run from the repository root with:
        Invoke-Pester ./Tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\IdentitySync\Modules\IdentitySync.Retry.psm1') -Force

    # Builds the exception a failed HTTP call raises, as the mocks do.
    function New-HttpError {
        param([int] $StatusCode, [int] $RetryAfterSeconds = 0)
        $exception = [System.InvalidOperationException]::new("HTTP $StatusCode`: simulated")
        $exception.Data['StatusCode'] = $StatusCode
        if ($RetryAfterSeconds) { $exception.Data['RetryAfterSeconds'] = $RetryAfterSeconds }
        $exception
    }

    # Returns a call that fails $Failures times with $StatusCode, then returns 'ok'.
    # $script:Calls counts every attempt.
    function New-FlakyCall {
        param([int] $Failures, [int] $StatusCode = 503, [int] $RetryAfterSeconds = 0)
        $script:Calls = 0
        $script:FailuresLeft = $Failures
        $script:FailStatus = $StatusCode
        $script:FailRetryAfter = $RetryAfterSeconds
        {
            $script:Calls++
            if ($script:FailuresLeft -gt 0) {
                $script:FailuresLeft--
                throw (New-HttpError -StatusCode $script:FailStatus -RetryAfterSeconds $script:FailRetryAfter)
            }
            'ok'
        }
    }

    # A Sleep stub that records each wait in $script:Waits instead of sleeping.
    $script:RecordSleep = { param($Seconds) $script:Waits.Add([double] $Seconds) }

    # Runs Invoke-WithRetry with the recording sleep and returns the error, if any.
    function Invoke-Retry {
        param([scriptblock] $Action, [hashtable] $Options = @{})
        $script:Waits = [System.Collections.Generic.List[double]]::new()
        try { $script:Result = Invoke-WithRetry -Action $Action -Sleep $RecordSleep @Options; $null }
        catch { $_ }
    }
}

Describe 'Invoke-WithRetry' {
    Context 'Success' {
        It 'returns the result of a call that works first time, without waiting' {
            Invoke-Retry (New-FlakyCall -Failures 0) | Should -BeNullOrEmpty
            $Result | Should -Be 'ok'
            $Calls | Should -Be 1
            $Waits | Should -HaveCount 0
        }

        It 'succeeds after transient failures: <StatusCode>' -ForEach @(
            @{ StatusCode = 429 }, @{ StatusCode = 502 }, @{ StatusCode = 503 }, @{ StatusCode = 504 }
        ) {
            Invoke-Retry (New-FlakyCall -Failures 2 -StatusCode $StatusCode) | Should -BeNullOrEmpty
            $Result | Should -Be 'ok'
            $Calls | Should -Be 3
        }
    }

    Context 'Giving up' {
        It 'stops after MaxAttempts and throws the last error' {
            $failure = Invoke-Retry (New-FlakyCall -Failures 10) @{ MaxAttempts = 4 }

            $Calls | Should -Be 4
            $failure.Exception.Data['StatusCode'] | Should -Be 503
        }

        It 'records how many attempts were made on the error' {
            $failure = Invoke-Retry (New-FlakyCall -Failures 10) @{ MaxAttempts = 3 }
            $failure.Exception.Data['Attempts'] | Should -Be 3
        }

        It 'does not retry a permanent failure: <StatusCode>' -ForEach @(
            @{ StatusCode = 400 }, @{ StatusCode = 401 }, @{ StatusCode = 404 }, @{ StatusCode = 409 }, @{ StatusCode = 422 }
        ) {
            $failure = Invoke-Retry (New-FlakyCall -Failures 1 -StatusCode $StatusCode)

            $Calls | Should -Be 1
            $failure.Exception.Data['StatusCode'] | Should -Be $StatusCode
            $failure.Exception.Data['Attempts'] | Should -Be 1
            $Waits | Should -HaveCount 0
        }

        It 'does not retry an error that has no HTTP status' {
            $failure = Invoke-Retry { $script:Calls++; throw 'not an HTTP error' }
            $failure | Should -Not -BeNullOrEmpty
            $Waits | Should -HaveCount 0
        }
    }

    Context 'Back-off' {
        It 'doubles the wait each time, with up to half the base delay of jitter' {
            Invoke-Retry (New-FlakyCall -Failures 3) @{ MaxAttempts = 4; BaseDelaySeconds = 1 } | Out-Null

            $Waits | Should -HaveCount 3
            $Waits[0] | Should -BeGreaterOrEqual 1; $Waits[0] | Should -BeLessOrEqual 1.5
            $Waits[1] | Should -BeGreaterOrEqual 2; $Waits[1] | Should -BeLessOrEqual 2.5
            $Waits[2] | Should -BeGreaterOrEqual 4; $Waits[2] | Should -BeLessOrEqual 4.5
        }

        It 'never waits longer than MaxDelaySeconds' {
            Invoke-Retry (New-FlakyCall -Failures 5) @{ MaxAttempts = 6; BaseDelaySeconds = 10; MaxDelaySeconds = 15 } | Out-Null
            ($Waits | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 15
        }

        It 'waits as long as Retry-After says on a 429' {
            Invoke-Retry (New-FlakyCall -Failures 1 -StatusCode 429 -RetryAfterSeconds 7) @{ BaseDelaySeconds = 1 } | Out-Null
            $Waits | Should -Be @(7)
        }

        It 'does not wait at all when BaseDelaySeconds is 0' {
            Invoke-Retry (New-FlakyCall -Failures 2) @{ BaseDelaySeconds = 0 } | Out-Null
            $Waits | Should -Be @(0, 0)
        }
    }

    Context 'Reporting' {
        It 'reports each retry with the attempt, status and wait' {
            $script:Reported = [System.Collections.Generic.List[object]]::new()
            $report = { param($Retry) $script:Reported.Add($Retry) }
            Invoke-Retry (New-FlakyCall -Failures 2) @{ Description = 'Get-MgUser E2001'; BaseDelaySeconds = 0; OnRetry = $report } | Out-Null

            $Reported | Should -HaveCount 2
            $Reported[0].Description | Should -Be 'Get-MgUser E2001'
            $Reported[0].Attempt | Should -Be 1
            $Reported[0].MaxAttempts | Should -Be 4
            $Reported[0].StatusCode | Should -Be 503
            $Reported[1].Attempt | Should -Be 2
        }

        It 'does not report the final, failed attempt as a retry' {
            $script:Reported = [System.Collections.Generic.List[object]]::new()
            $report = { param($Retry) $script:Reported.Add($Retry) }
            Invoke-Retry (New-FlakyCall -Failures 10) @{ MaxAttempts = 3; BaseDelaySeconds = 0; OnRetry = $report } | Out-Null

            $Reported | Should -HaveCount 2
        }
    }
}
