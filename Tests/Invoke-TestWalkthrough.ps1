<#
.SYNOPSIS
    Walks through testing the identity sync, step by step, checking each result.

.DESCRIPTION
    Runs the manual test steps for the identity sync in order. For each step
    it shows what is being tested and the command, runs it (with its normal
    coloured output), then checks the result automatically and prints PASS or
    FAIL for each check. It waits for Enter between steps unless -NoPause is
    given.

    The steps:
       1. All automated Pester tests
       2. A dry run changes nothing
       3. First live run: every test case reaches the expected stage
       4. The saved state holds no passwords or tokens
       5. Running the same input again does nothing twice
       6. Failures that clear up: only the failed stage reruns
       7. Restart safety: a run that stops part-way carries on
       8. A lost state file does not create duplicates
       9. Mailbox timeout (by its Pester tests)
      10. The disable safety limit
      11. Put everything back

    Steps 6, 7 and 10 edit the mock files to set up their test. Both mock
    files are backed up first and always restored at the end, even if the
    walkthrough fails or is stopped with Ctrl+C. The sync state is reset at
    the start and the end.

.PARAMETER NoPause
    Run every step without waiting for Enter in between.

.EXAMPLE
    .\Tests\Invoke-TestWalkthrough.ps1
    Runs the walkthrough, pausing after each step.

.EXAMPLE
    .\Tests\Invoke-TestWalkthrough.ps1 -NoPause
    Runs every step straight through.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'NoPause', Justification = 'Read inside Wait-NextStep.')]
[CmdletBinding()]
param([switch] $NoPause)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Paths
$repoRoot      = Split-Path -Path $PSScriptRoot -Parent
$sync          = Join-Path $repoRoot 'IdentitySync\Scripts\Invoke-IdentitySync.ps1'
$mocksFolder   = Join-Path $repoRoot 'IdentitySync\Mocks'
$behaviourPath = Join-Path $mocksFolder 'mock-behaviour.json'
$workersPath   = Join-Path $mocksFolder 'HRIS-Workers.json'
$stateFolder   = Join-Path $repoRoot 'IdentitySync\State'
$syncStatePath = Join-Path $stateFolder 'sync-state.json'
$mockDataPath  = Join-Path $stateFolder 'mock-services.json'

# Copies of the mock files, restored at the end whatever happens.
$backupFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('identitysync-walkthrough-' + [guid]::NewGuid())
#endregion

#region Helpers
$script:Passed = 0
$script:Failed = 0
$script:FailedChecks = [System.Collections.Generic.List[string]]::new()

# Prints the heading for a step: what is tested, the command, and what to look for.
function Write-Step {
    param([int] $Number, [string] $Title, [string] $Command, [string[]] $LookFor = @())

    Write-Host ''
    Write-Host ('#' * 78) -ForegroundColor Cyan
    Write-Host ("STEP $Number. $Title") -ForegroundColor Cyan
    Write-Host ('#' * 78) -ForegroundColor Cyan
    if ($Command) {
        Write-Host 'Command:' -ForegroundColor DarkGray
        foreach ($line in $Command -split "`n") { Write-Host "  $line" -ForegroundColor White }
    }
    if ($LookFor.Count -gt 0) {
        Write-Host 'What to look for:' -ForegroundColor DarkGray
        foreach ($item in $LookFor) { Write-Host "  - $item" -ForegroundColor Gray }
    }
    Write-Host ''
}

# Prints the heading before the automatic checks for a step.
function Write-CheckHeading {
    Write-Host ''
    Write-Host 'Automatic checks:' -ForegroundColor Cyan
}

# Records and prints one check as PASS or FAIL.
function Assert-Check {
    param([string] $Description, [bool] $Condition)

    if ($Condition) {
        $script:Passed++
        Write-Host '  PASS  ' -ForegroundColor Green -NoNewline
    }
    else {
        $script:Failed++
        $script:FailedChecks.Add($Description)
        Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline
    }
    Write-Host $Description
}

# Waits for Enter before the next step, unless -NoPause was given.
function Wait-NextStep {
    if ($NoPause) { return }
    Write-Host ''
    Read-Host 'Press Enter for the next step (Ctrl+C to stop)' | Out-Null
}

# Runs the sync script with the given switches, showing its normal output.
function Invoke-Sync {
    param([switch] $Apply, [switch] $ResetState)
    & $sync -Apply:$Apply -ResetState:$ResetState
}

# Reads a JSON file as an object. Windows PowerShell 5.1 returns a JSON
# array as one object, so the result is stored before it is used.
function Read-Json {
    param([string] $Path)
    $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path))
    , $parsed
}

# Writes an object to a JSON file, UTF-8 without a BOM, as the mock files are.
function Write-Json {
    param([string] $Path, $InputObject)
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $InputObject -Depth 6), [System.Text.UTF8Encoding]::new($false))
}

# The stage each worker has reached, from the sync state file.
function Get-Stage {
    param([string] $EmployeeId)
    if (-not (Test-Path $syncStatePath)) { return $null }
    $entry = (Read-Json $syncStatePath).workers.PSObject.Properties[$EmployeeId]
    if ($entry) { return $entry.Value.stage }
    return $null
}

# A worker's value from the sync state file, such as entraObjectId.
function Get-StateValue {
    param([string] $EmployeeId, [string] $Field)
    $entry = (Read-Json $syncStatePath).workers.PSObject.Properties[$EmployeeId]
    if ($entry) { return $entry.Value.$Field }
    return $null
}

# The mock Entra users with this employeeId, from the saved mock data. The
# leading comma keeps it a list even with one user or none, so .Count works.
function Get-MockUser {
    param([string] $EmployeeId)
    , @((Read-Json $mockDataPath).Users | Where-Object { $_.employeeId -ceq $EmployeeId })
}

# A worker's email in the mock HRIS, from the saved mock data.
function Get-MockHRISEmail {
    param([string] $EmployeeId)
    $worker = @((Read-Json $mockDataPath).HRISWorkers | Where-Object { $_.PSObject.Properties['employeeId'] -and $_.employeeId -ceq $EmployeeId })
    if ($worker) { return $worker[0].email }
    return $null
}

# Runs Pester and returns the result.
function Invoke-Tests {
    param([string] $Path, [string] $Filter)
    $parameters = @{ Path = $Path; Output = 'Detailed'; PassThru = $true }
    if ($Filter) { $parameters['FullNameFilter'] = $Filter }
    Invoke-Pester @parameters
}

# Deletes the sync state and saved mock data, without running the sync.
function Clear-SyncState {
    foreach ($path in $syncStatePath, $mockDataPath) {
        if (Test-Path $path) { Remove-Item $path }
    }
}
#endregion

# The test-case workers who are joiners, and who start with an Entra identity.
$joiners  = 'E9001', 'E9002', 'E9011', 'E9012', 'E9013', 'E9014', 'E9015'
$existing = 'E1001', 'E1002', 'E1003', 'E1004', 'E1005', 'E9003', 'E9016', 'E9017'

Import-Module Pester -MinimumVersion 5.0 -Force

# Back up the mock files, and start from an empty state.
New-Item -ItemType Directory -Path $backupFolder | Out-Null
Copy-Item -Path $behaviourPath, $workersPath -Destination $backupFolder
Clear-SyncState

try {
    #region Step 1
    Write-Step 1 'All automated Pester tests' 'Invoke-Pester .\Tests -Output Detailed' @(
        'Every test listed with [+]; the last line is "Tests Passed: ..., Failed: 0"')
    $tests = Invoke-Tests -Path (Join-Path $repoRoot 'Tests')

    Write-CheckHeading
    Assert-Check "All $($tests.PassedCount + $tests.FailedCount) Pester tests passed" ($tests.FailedCount -eq 0 -and $tests.PassedCount -gt 0)
    Wait-NextStep
    #endregion

    #region Step 2
    Write-Step 2 'A dry run changes nothing' '.\IdentitySync\Scripts\Invoke-IdentitySync.ps1' @(
        'The banner says DRY RUN',
        'All 23 workers listed with their tables, but no Result lines and no "Created user" lines',
        'The end says "The sync state is empty"')
    Invoke-Sync

    Write-CheckHeading
    Assert-Check 'No sync state file was written' (-not (Test-Path $syncStatePath))
    Assert-Check 'No mock data was saved' (-not (Test-Path $mockDataPath))
    Wait-NextStep
    #endregion

    #region Step 3
    Write-Step 3 'First live run' '.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply' @(
        'E9001, E9002, E9013: Complete, email written back',
        'E9014: Complete with alex.clarke2@example.com, the address Exchange assigned',
        'E9003: Update Done, then Complete NoChange; E9004: Disable Done',
        'E9011 IdentityFailed, E9012 MailboxPending, E9015 WriteBackFailed, E9017 ManualReview')
    Invoke-Sync -Apply

    Write-CheckHeading
    foreach ($id in 'E1001', 'E1002', 'E1003', 'E1004', 'E1005', 'E9001', 'E9002', 'E9003', 'E9013', 'E9014', 'E9016') {
        Assert-Check "$id reached Complete" ((Get-Stage $id) -eq 'Complete')
    }
    Assert-Check 'E9011 (transient failure) is IdentityFailed, with no identity created' (((Get-Stage 'E9011') -eq 'IdentityFailed') -and ((Get-MockUser 'E9011').Count -eq 0))
    Assert-Check 'E9012 (mailbox not ready) is MailboxPending, with no HRIS email' (((Get-Stage 'E9012') -eq 'MailboxPending') -and -not (Get-MockHRISEmail 'E9012'))
    Assert-Check 'E9015 (write-back failure) is WriteBackFailed, with its identity created' (((Get-Stage 'E9015') -eq 'WriteBackFailed') -and ((Get-MockUser 'E9015').Count -eq 1))
    Assert-Check 'E9017 (conflicting email) is ManualReview, HRIS address unchanged' (((Get-Stage 'E9017') -eq 'ManualReview') -and ((Get-MockHRISEmail 'E9017') -eq 'q.hall.old@example.com'))
    Assert-Check 'E9014 got the assigned address alex.clarke2@example.com in the HRIS' ((Get-MockHRISEmail 'E9014') -eq 'alex.clarke2@example.com')
    Assert-Check 'E9004 (leaver) is disabled in Entra' (-not (Get-MockUser 'E9004')[0].accountEnabled)
    Assert-Check 'E9003 (mover) has department Finance in Entra' ((Get-MockUser 'E9003')[0].department -eq 'Finance')
    Assert-Check 'No ManualReview record got an identity (E9005-E9009)' (@('E9005', 'E9006', 'E9007', 'E9008', 'E9009' | Where-Object { (Get-MockUser $_).Count -gt 0 }).Count -eq 0)
    Wait-NextStep
    #endregion

    #region Step 4
    Write-Step 4 'The saved state holds no secrets' "Get-Content .\IdentitySync\State\sync-state.json`nSelect-String -Path .\IdentitySync\State\*.json -Pattern 'password','token'" @(
        'Each worker has stage, entraObjectId, primarySmtpAddress, mailboxChecks and lastError',
        'Select-String finds nothing')
    Get-Content $syncStatePath
    $secrets = @(Select-String -Path (Join-Path $stateFolder '*.json') -Pattern 'password', 'token')

    Write-CheckHeading
    Assert-Check 'Neither state file contains "password" or "token"' ($secrets.Count -eq 0)
    Wait-NextStep
    #endregion

    #region Step 5
    Write-Step 5 'Running the same input again does nothing twice' '.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply' @(
        'Finished workers say "Skipped: Already Complete in an earlier run"',
        'E9003 and E9004 are not changed again',
        'Only E9011, E9012 and E9015 do anything; E9015 has no "Creating user" line')
    $objectIdBefore = Get-StateValue 'E9015' 'entraObjectId'
    Invoke-Sync -Apply

    Write-CheckHeading
    foreach ($id in $joiners + $existing) {
        $count = (Get-MockUser $id).Count
        Assert-Check "$id has at most one Entra identity ($count)" ($count -le 1)
    }
    Assert-Check 'E9015 kept the same Entra object ID' ((Get-StateValue 'E9015' 'entraObjectId') -eq $objectIdBefore)
    Assert-Check 'E9012 has had 6 mailbox checks over the two runs' ((Get-StateValue 'E9012' 'mailboxChecks') -eq 6)
    Wait-NextStep
    #endregion

    #region Step 6
    Write-Step 6 'Failures that clear up: only the failed stage reruns' "Change both ""times"": ""always"" to 1 in mock-behaviour.json`n.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply" @(
        'E9011 becomes Complete: its identity is created now',
        'E9015 becomes Complete with no "Creating user" line: only the write-back ran')
    $behaviour = Read-Json $behaviourPath
    $behaviour.entra.failures.E9011.times = 1
    $behaviour.hris.failures.E9015.times  = 1
    Write-Json $behaviourPath $behaviour
    $objectIdBefore = Get-StateValue 'E9015' 'entraObjectId'
    Invoke-Sync -Apply

    Write-CheckHeading
    Assert-Check 'E9011 reached Complete, with one identity' (((Get-Stage 'E9011') -eq 'Complete') -and ((Get-MockUser 'E9011').Count -eq 1))
    Assert-Check 'E9015 reached Complete' ((Get-Stage 'E9015') -eq 'Complete')
    Assert-Check 'E9015 kept the same identity (not created again)' (((Get-StateValue 'E9015' 'entraObjectId') -eq $objectIdBefore) -and ((Get-MockUser 'E9015').Count -eq 1))
    Assert-Check 'E9015 has its email in the HRIS' ((Get-MockHRISEmail 'E9015') -eq 'jordan.wilson@example.com')
    Wait-NextStep
    #endregion

    #region Step 7
    Write-Step 7 'Restart safety: a run that stops part-way carries on' "Set ""readyAfterChecks"": 5 in mock-behaviour.json`n.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply -ResetState`n.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply" @(
        'First run: the new joiners stop at MailboxPending (3 checks are not enough)',
        'Second run: they reach Complete with no "Creating user" lines')
    $behaviour = Read-Json $behaviourPath
    $behaviour.exchange.readyAfterChecks = 5
    Write-Json $behaviourPath $behaviour

    Write-Host '--- First run (stops part-way) ---' -ForegroundColor Cyan
    Invoke-Sync -Apply -ResetState
    $slowJoiners = 'E9001', 'E9002', 'E9013', 'E9014'
    $objectIds = @{}
    foreach ($id in $slowJoiners) { $objectIds[$id] = Get-StateValue $id 'entraObjectId' }
    $pendingAfterFirst = @($slowJoiners | Where-Object { (Get-Stage $_) -eq 'MailboxPending' }).Count

    Write-Host ''
    Write-Host '--- Second run (carries on) ---' -ForegroundColor Cyan
    Invoke-Sync -Apply

    Write-CheckHeading
    Assert-Check 'After the first run, E9001, E9002, E9013 and E9014 were MailboxPending' ($pendingAfterFirst -eq $slowJoiners.Count)
    foreach ($id in $slowJoiners) {
        Assert-Check "$id reached Complete on the second run with the same identity" (((Get-Stage $id) -eq 'Complete') -and ((Get-StateValue $id 'entraObjectId') -eq $objectIds[$id]) -and ((Get-MockUser $id).Count -eq 1))
    }
    Wait-NextStep
    #endregion

    #region Step 8
    Write-Step 8 'A lost state file does not create duplicates' "Remove-Item .\IdentitySync\State\sync-state.json`n.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply" @(
        'No "Creating user" lines for anyone who already exists',
        'Existing identities are found ("Found 1 user(s)") and used')
    Remove-Item $syncStatePath
    Invoke-Sync -Apply

    Write-CheckHeading
    foreach ($id in $joiners) {
        $count = (Get-MockUser $id).Count
        Assert-Check "$id has at most one Entra identity ($count)" ($count -le 1)
    }
    Assert-Check 'A new sync state was written' (Test-Path $syncStatePath)
    Wait-NextStep
    #endregion

    #region Step 9
    Write-Step 9 'Mailbox timeout' "Invoke-Pester .\Tests\IdentitySync.Pipeline.Tests.ps1 -FullNameFilter '*Mailbox*' -Output Detailed" @(
        'Needs a simulated 25 hours, so it is covered by the Pester tests',
        '"stops at MailboxTimeout once the timeout has passed" and "leaves a timed-out worker alone" pass')
    $tests = Invoke-Tests -Path (Join-Path $repoRoot 'Tests\IdentitySync.Pipeline.Tests.ps1') -Filter '*Mailbox*'

    Write-CheckHeading
    Assert-Check "All $($tests.PassedCount) mailbox tests passed, including MailboxTimeout" ($tests.FailedCount -eq 0 -and $tests.PassedCount -gt 0)
    Wait-NextStep
    #endregion

    #region Step 10
    $newLeavers = 'E1001', 'E1002', 'E1003', 'E1004', 'E1005', 'E9016'
    Write-Step 10 'The disable safety limit' "Make $($newLeavers -join ', ') leavers in HRIS-Workers.json`n.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply -ResetState" @(
        'With E9004 that is 7 disables, more than the limit of 5',
        'Every Disable shows "Skipped: 7 disables planned, more than the limit of 5 per run; none applied"')
    $workers = Read-Json $workersPath
    foreach ($worker in $workers) {
        if ($worker.PSObject.Properties['employeeId'] -and ($worker.employeeId -in $newLeavers)) {
            $worker.status  = 'Inactive'
            $worker.endDate = '2026-11-01'
        }
    }
    Write-Json $workersPath $workers
    Invoke-Sync -Apply -ResetState

    Write-CheckHeading
    foreach ($id in $newLeavers + 'E9004') {
        Assert-Check "$id is still enabled in Entra (no disable applied)" ((Get-MockUser $id)[0].accountEnabled)
    }
    Wait-NextStep
    #endregion
}
finally {
    #region Step 11
    Write-Step 11 'Put everything back' "git restore IdentitySync/Mocks/mock-behaviour.json IdentitySync/Mocks/HRIS-Workers.json`n.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -ResetState" @(
        'The mock files are back as they were, and the state is cleared')

    # Restore from the backup taken at the start, whatever happened above.
    Copy-Item -Path (Join-Path $backupFolder 'mock-behaviour.json') -Destination $behaviourPath -Force
    Copy-Item -Path (Join-Path $backupFolder 'HRIS-Workers.json') -Destination $workersPath -Force
    Remove-Item -Path $backupFolder -Recurse -Force
    Clear-SyncState
    Write-Host 'Mock files restored from the backup and sync state cleared.' -ForegroundColor Green

    Write-CheckHeading
    $changed = @(git -C $repoRoot status --porcelain -- 'IdentitySync/Mocks')
    Assert-Check 'The mock files match the repository again' ($changed.Count -eq 0)
    Assert-Check 'The sync state is cleared' (-not (Test-Path $syncStatePath) -and -not (Test-Path $mockDataPath))
    #endregion

    #region Summary
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    $colour = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("Walkthrough finished: {0} checks passed, {1} failed." -f $script:Passed, $script:Failed) -ForegroundColor $colour
    foreach ($check in $script:FailedChecks) { Write-Host "  FAIL  $check" -ForegroundColor Red }
    Write-Host ('=' * 78) -ForegroundColor Cyan
    #endregion
}

if ($script:Failed -gt 0) { exit 1 }
