<#
.SYNOPSIS
    Decides the Entra ID identity action for every worker in an HRIS export.

.DESCRIPTION
    The entry point for the identity sync. It reads the HRIS workers file and
    the current Entra identities, then works out what should happen to each
    worker: Create, Update, Disable, NoChange or ManualReview.

    What the script does, in order:
      1. Reads the HRIS workers JSON and the Entra identities JSON.
      2. Validates every record and decides an action for each employeeId,
         using the rules in Modules\IdentitySync.psm1.
      3. Prints each decision with its reason and any attribute changes.
      4. Lists Entra identities that have no HRIS record. These are reported
         only: a worker missing from one file is never disabled.
      5. Prints a summary of how many workers got each action.

    This version is a dry run only: it decides but changes nothing. Applying
    decisions against the Entra ID, Exchange Online and HRIS mocks is added
    in a later step.

.PARAMETER WorkersPath
    The HRIS workers JSON file. Defaults to the mock in
    IdentitySync\Mocks\hris-workers.json.

.PARAMETER IdentitiesPath
    The Entra identities JSON file. Defaults to the mock in
    IdentitySync\Mocks\entra-identities.json.

.PARAMETER Today
    The date the rules treat as today. Defaults to the current date.

.EXAMPLE
    .\Invoke-IdentitySync.ps1
    Shows the decision for every worker in the default files.
#>
[CmdletBinding()]
param(
    [string] $WorkersPath = (Join-Path $PSScriptRoot '..\Mocks\hris-workers.json'),

    [string] $IdentitiesPath = (Join-Path $PSScriptRoot '..\Mocks\entra-identities.json'),

    [datetime] $Today = (Get-Date).Date
)

# Fail fast: treat undefined variables and any error as a stop.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\Modules\IdentitySync.psm1') -Force

#region Settings
# Colour for each action in the terminal.
$actionColours = @{
    Create       = 'Green'
    Update       = 'Cyan'
    Disable      = 'Yellow'
    NoChange     = 'DarkGray'
    ManualReview = 'Red'
}
#endregion

#region Helpers
# Reads a JSON array file and returns one item per element. Windows PowerShell
# 5.1 returns a JSON array as a single object, so it is stored first and then
# wrapped in @() to give the same result on every PowerShell version.
function Read-JsonArray {
    param([string] $Path, [string] $Description)

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -Path $fullPath -PathType Leaf)) {
        throw "$Description file not found: $fullPath"
    }

    try {
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($fullPath))
    }
    catch {
        throw "$Description file is not valid JSON: $fullPath. $($_.Exception.Message)"
    }
    return , @($parsed)
}

# Prints one decision, for example:
#
#   Update        E9003      Quinn Roberts
#                 Changed attributes: department, managerEmployeeId
#                   department: Operations -> Finance
function Write-Decision {
    param($Decision)

    $colour = $actionColours[$Decision.Action]
    $id     = if ($Decision.EmployeeId) { $Decision.EmployeeId } else { '(missing)' }

    Write-Host ('{0,-14}' -f $Decision.Action) -ForegroundColor $colour -NoNewline
    Write-Host ('{0,-11}' -f $id) -ForegroundColor Cyan -NoNewline
    Write-Host $Decision.Name -ForegroundColor White
    Write-Host ('{0,-14}{1}' -f '', $Decision.Reason) -ForegroundColor DarkGray

    # Updates and Disables list each attribute that would change. A Create
    # sets every attribute, so listing them adds nothing.
    if ($Decision.Action -in 'Update', 'Disable') {
        foreach ($attribute in $Decision.Changes.Keys) {
            $change = $Decision.Changes[$attribute]
            $from   = if ($null -eq $change.From) { '-' } else { $change.From }
            $to     = if ($null -eq $change.To)   { '-' } else { $change.To }
            Write-Host ('{0,-16}{1}: {2} -> {3}' -f '', $attribute, $from, $to) -ForegroundColor $colour
        }
    }
}
#endregion

#region Read inputs
$workers    = Read-JsonArray -Path $WorkersPath -Description 'Workers'
$identities = Read-JsonArray -Path $IdentitiesPath -Description 'Identities'

Write-Host ''
Write-Host 'DRY RUN: decisions only, nothing is changed.' -ForegroundColor Yellow
Write-Host ('Read {0} HRIS records and {1} Entra identities. Today is {2}.' -f
    $workers.Count, $identities.Count, $Today.ToString('yyyy-MM-dd')) -ForegroundColor DarkGray
#endregion

#region Decide
$decisions = @(Get-IdentityPlan -Workers $workers -Identities $identities -Today $Today)

Write-Host ''
foreach ($decision in $decisions) {
    Write-Decision -Decision $decision
}
#endregion

#region Identities with no HRIS record
# Reported so someone can follow up, but never disabled automatically.
$unmatched = @(Get-UnmatchedIdentity -Workers $workers -Identities $identities)
if ($unmatched.Count -gt 0) {
    Write-Host ''
    Write-Host ('{0} Entra identities have no HRIS record and are left unchanged:' -f $unmatched.Count) -ForegroundColor Yellow
    foreach ($identity in $unmatched) {
        Write-Host ('  {0,-11}{1} {2}' -f $identity.employeeId, $identity.givenName, $identity.surname) -ForegroundColor DarkGray
    }
}
#endregion

#region Summary
# One line per action, in a fixed order, including actions with no workers.
Write-Host ''
Write-Host ('Decided {0} employeeIds from {1} records:' -f $decisions.Count, $workers.Count) -ForegroundColor Green
foreach ($action in 'Create', 'Update', 'Disable', 'NoChange', 'ManualReview') {
    $count = @($decisions | Where-Object { $_.Action -eq $action }).Count
    Write-Host ('  {0,-14}{1}' -f $action, $count) -ForegroundColor $actionColours[$action]
}
#endregion
