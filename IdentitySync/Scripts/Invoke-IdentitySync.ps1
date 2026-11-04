<#
.SYNOPSIS
    Syncs HRIS workers to Entra ID and writes each joiner's confirmed email
    address back to the HRIS. A dry run unless -Apply is given.

.DESCRIPTION
    The entry point for the identity sync. What the script does, in order:
      1. Sets up the mock Microsoft Graph, Exchange Online and HRIS services,
         carrying on from the last run's data if there is any, and connects.
      2. Reads the HRIS workers JSON and the sync state from the last run.
      3. Reads the current Entra identities with Get-MgUser, validates every
         HRIS record and decides an action for each employeeId: Create,
         Update, Disable, NoChange or ManualReview. With -Apply, it then:
           a. applies Update and Disable decisions to existing identities;
           b. runs every active worker through three stages, saving the sync
              state after each one: identity ready (created if needed),
              mailbox ready (primary SMTP address known), and email written
              back to the HRIS.
      4. Prints each decision, with the HRIS record next to the Entra account
         so you can see why it was made, and lists Entra identities that have
         no HRIS record. Those are reported only: a worker missing from one
         file is never disabled.
      5. With -Apply, prints the result for each change and each worker's
         stages, and a summary by stage. Without -Apply, lists what earlier
         runs left in progress.

    Running the same input again is safe: finished workers are skipped,
    and a worker part-way through carries on from the stage it reached, so
    no identity or mailbox is ever created twice. See
    Modules\IdentitySync.Pipeline.psm1 for the stages.

    State is kept in IdentitySync\State (not committed to git):
      sync-state.json      the stage each worker has reached
      mock-services.json   the mock services' data, standing in for the
                           real services remembering what was created

    The work is done by the modules in IdentitySync\Modules:
      IdentitySync.psm1           the validation and decision rules
      IdentitySync.Pipeline.psm1  applying decisions, stages and sync state
      IdentitySync.Mocks.psm1     the mock Graph, Exchange and HRIS services
      IdentitySync.Files.psm1     reading and writing JSON files
      IdentitySync.Display.psm1   everything printed to the terminal

.PARAMETER Apply
    Make the changes. Without it, the run is a dry run that changes nothing.

.PARAMETER WorkersPath
    The HRIS workers JSON file. Defaults to IdentitySync\Mocks\HRIS-Workers.json.

.PARAMETER IdentitiesPath
    The Entra identities the mock tenant starts with, used on the first run
    (or after -ResetState). Defaults to IdentitySync\Mocks\Entra-Identities.json.

.PARAMETER BehaviourPath
    The mock failures and mailbox timing. Defaults to
    IdentitySync\Mocks\mock-behaviour.json.

.PARAMETER StatePath
    The folder for the state files. Defaults to IdentitySync\State.

.PARAMETER ResetState
    Deletes the sync state and the saved mock data first, so the run starts
    from the mock files again.

.PARAMETER Today
    The date the decision rules treat as today. Defaults to the current date.

.EXAMPLE
    .\Invoke-IdentitySync.ps1
    Dry run: shows the decision for every worker, changes nothing.

.EXAMPLE
    .\Invoke-IdentitySync.ps1 -Apply
    Applies the decisions and runs every worker through the stages.

.EXAMPLE
    .\Invoke-IdentitySync.ps1 -Apply -ResetState
    Starts again from the mock files, then applies.
#>
[CmdletBinding()]
param(
    [switch] $Apply,

    [string] $WorkersPath = (Join-Path $PSScriptRoot '..\Mocks\HRIS-Workers.json'),

    [string] $IdentitiesPath = (Join-Path $PSScriptRoot '..\Mocks\Entra-Identities.json'),

    [string] $BehaviourPath = (Join-Path $PSScriptRoot '..\Mocks\mock-behaviour.json'),

    [string] $StatePath = (Join-Path $PSScriptRoot '..\State'),

    [switch] $ResetState,

    [datetime] $Today = (Get-Date).Date
)

# Fail fast: treat undefined variables and any error as a stop.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load the modules. -Force reloads them, so edits are picked up on the next run.
# In production, IdentitySync.Mocks.psm1 is replaced by the real modules:
# Microsoft.Graph.Users, ExchangeOnlineManagement and an HRIS API client.
$modules = Join-Path $PSScriptRoot '..\Modules'
foreach ($module in 'IdentitySync.psm1', 'IdentitySync.Files.psm1', 'IdentitySync.Mocks.psm1',
                    'IdentitySync.Pipeline.psm1', 'IdentitySync.Display.psm1') {
    Import-Module (Join-Path $modules $module) -Force
}

$syncStatePath = Join-Path $StatePath 'sync-state.json'
$mockDataPath  = Join-Path $StatePath 'mock-services.json'

# Start again from the mock files if asked.
if ($ResetState) {
    foreach ($path in $syncStatePath, $mockDataPath) {
        if (Test-Path -Path $path) { Remove-Item -Path $path }
    }
    Write-Host 'Sync state and saved mock data deleted; starting from the mock files.' -ForegroundColor Yellow
}

# The HRIS API token comes from the environment, never from a file or the
# command line, and is never printed. Without one, the mock's own token is used.
$hrisToken = $env:IDENTITYSYNC_HRIS_TOKEN
if (-not $hrisToken) {
    $hrisToken = 'mock-hris-token'
    Write-Host 'IDENTITYSYNC_HRIS_TOKEN is not set; using the mock HRIS token.' -ForegroundColor DarkGray
}

# 1. Set up the mock services and connect, as production would with managed identities.
Write-SectionHeading -Text 'Setup'
$behaviour = Get-Content -Path $BehaviourPath -Raw | ConvertFrom-Json
Initialize-MockServices -Identities (Read-JsonArray -Path $IdentitiesPath -Description 'Identities') `
    -Workers (Read-JsonArray -Path $WorkersPath -Description 'Workers') `
    -Behaviour $behaviour -HRISApiToken $hrisToken -FromPath $mockDataPath
Connect-MgGraph -Identity -NoWelcome
Connect-ExchangeOnline -ManagedIdentity -Organization 'example.onmicrosoft.com' -ShowBanner:$false

# 2. Read the inputs and where the last run got to.
$workers = Read-JsonArray -Path $WorkersPath -Description 'Workers'
$state   = Read-SyncState -Path $syncStatePath

# Saving after every stage is what makes a restart safe: whatever was done is on disk.
$saveAll = {
    Save-SyncState -State $state -Path $syncStatePath
    Save-MockServices -Path $mockDataPath
}

# 3 and 4. Go through the workers one at a time. For each: print the decision
# and the data behind it, then (with -Apply) make the changes, with the mock
# calls indented under the worker, then print the result.
Write-RunHeader -WorkerCount $workers.Count -Today $Today -Apply:$Apply

$showDecision = {
    param($Decision, $Number, $Total)
    Set-MockActivityOutput -Enabled $true -Indent 0
    Write-Decision -Decision $Decision -Number $Number -Total $Total
    Set-MockActivityOutput -Enabled $true -Indent 14
}
$showOutcome = {
    param($Decision, $Change, $Stages)
    Write-WorkerOutcome -Decision $Decision -Change $Change -Stages $Stages
}

try {
    $run = Invoke-IdentitySyncRun -Workers $workers -State $state -Apply:$Apply -Today $Today `
        -HRISToken $hrisToken -OnChange $(if ($Apply) { $saveAll } else { $null }) `
        -OnDecision $showDecision -OnWorkerDone $(if ($Apply) { $showOutcome } else { $null })
}
finally {
    Set-MockActivityOutput -Enabled $true -Indent 0
}

# 5. The summary: identities left alone, decisions, and where every worker has got to.
Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkGray
Write-SectionHeading -Text 'Summary'
Write-UnmatchedIdentity -Identities $run.Unmatched
Write-PlanSummary -Decisions $run.Decisions -RecordCount $workers.Count

if ($Apply) {
    & $saveAll
    Write-StageSummary -State $state
    Write-Host ''
    Write-Host "Sync state saved to $((Resolve-Path $syncStatePath).Path)" -ForegroundColor DarkGray
}
else {
    Write-StageSummary -State $state -Title 'Left in progress by earlier runs (from the sync state):'
}
