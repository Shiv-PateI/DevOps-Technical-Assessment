<#
.SYNOPSIS
    Decides the Entra ID identity action for every worker in an HRIS export.

.DESCRIPTION
    The entry point for the identity sync. It reads the HRIS workers file and
    the current Entra identities, then works out what should happen to each
    worker: Create, Update, Disable, NoChange or ManualReview.

    What the script does, in order:
      1. Reads the HRIS workers JSON and the Entra identities JSON.
      2. Validates every record and decides an action for each employeeId.
      3. Prints each decision with its reason, a side-by-side table of the
         worker's HRIS record and their Entra account (with differences
         highlighted, so you can see why the decision was made), and any
         attribute changes.
      4. Lists Entra identities that have no HRIS record. These are reported
         only: a worker missing from one file is never disabled.
      5. Prints a summary of how many workers got each action.

    The work is done by three modules in IdentitySync\Modules:
      IdentitySync.psm1          the validation and decision rules
      IdentitySync.Files.psm1    reading the JSON files
      IdentitySync.Display.psm1  everything printed to the terminal

    This version is a dry run only: it decides but changes nothing. Applying
    decisions against the Entra ID, Exchange Online and HRIS mocks is added
    in a later step.

.PARAMETER WorkersPath
    The HRIS workers JSON file. Defaults to the mock in
    IdentitySync\Mocks\HRIS-Workers.json.

.PARAMETER IdentitiesPath
    The Entra identities JSON file. Defaults to the mock in
    IdentitySync\Mocks\Entra-Identities.json.

.PARAMETER Today
    The date the rules treat as today. Defaults to the current date.

.EXAMPLE
    .\Invoke-IdentitySync.ps1
    Shows the decision for every worker in the default files.
#>
[CmdletBinding()]
param(
    [string] $WorkersPath = (Join-Path $PSScriptRoot '..\Mocks\HRIS-Workers.json'),

    [string] $IdentitiesPath = (Join-Path $PSScriptRoot '..\Mocks\Entra-Identities.json'),

    [datetime] $Today = (Get-Date).Date
)

# Fail fast: treat undefined variables and any error as a stop.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load the modules. -Force reloads them, so edits are picked up on the next run.
$modules = Join-Path $PSScriptRoot '..\Modules'
Import-Module (Join-Path $modules 'IdentitySync.psm1') -Force
Import-Module (Join-Path $modules 'IdentitySync.Files.psm1') -Force
Import-Module (Join-Path $modules 'IdentitySync.Display.psm1') -Force

# 1. Read the inputs.
$workers    = Read-JsonArray -Path $WorkersPath -Description 'Workers'
$identities = Read-JsonArray -Path $IdentitiesPath -Description 'Identities'
Write-RunHeader -WorkerCount $workers.Count -IdentityCount $identities.Count -Today $Today

# 2 and 3. Decide an action for each employeeId, and print each decision.
$decisions = @(Get-IdentityPlan -Workers $workers -Identities $identities -Today $Today)
foreach ($decision in $decisions) {
    Write-Decision -Decision $decision
}

# 4. Report Entra identities with no HRIS record. These are never changed.
$unmatched = @(Get-UnmatchedIdentity -Workers $workers -Identities $identities)
Write-UnmatchedIdentity -Identities $unmatched

# 5. Summarise.
Write-PlanSummary -Decisions $decisions -RecordCount $workers.Count
