# PSScriptAnalyzer settings for this repository, used locally and in CI:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
#
# CI fails on any Error or Warning. Information-level findings (such as
# positional parameters) are reported but do not fail the build.
#
# Three rules are turned off for the whole repository because they conflict
# with deliberate design choices. Everything else is checked, and the few
# individual exceptions are suppressed in the code next to the function they
# apply to, each with a justification.
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Terminal output is the point of the Display module, the dry-run
        # report and the test walkthrough. Write-Host writes to the
        # information stream (PowerShell 5+), so it can still be captured or
        # silenced with 6>$null, which the tests do.
        'PSAvoidUsingWriteHost'

        # The sync's safety model is an explicit dry run by default and
        # -Apply to make changes, rather than -WhatIf on each function. Most
        # functions this rule flags (New-AuditLog, New-SyncState, New-Decision)
        # build objects in memory and change nothing.
        'PSUseShouldProcessForStateChangingFunctions'

        # Names such as Get-SyncSettings and Initialize-MockServices describe
        # a set of settings or services, and Initialize-MockServices sets up
        # all three mock services at once.
        'PSUseSingularNouns'
    )
}
