<#
.SYNOPSIS
    Reading the identity sync's JSON files.

.DESCRIPTION
    File handling shared by the identity sync scripts, kept apart from the
    decision rules and the terminal output.

    Public functions:
      Read-JsonArray    Reads a JSON file that holds an array, with clear
                        errors when the file is missing or not valid JSON.
#>

Set-StrictMode -Version Latest

function Read-JsonArray {
    <#
    .SYNOPSIS
        Reads a JSON array file and returns it as an array, one item per element.
    .DESCRIPTION
        Windows PowerShell 5.1 returns a JSON array as a single object, so it
        is stored first and then wrapped in @() to give the same result on
        every PowerShell version. The array is returned as one object (with a
        leading comma) so that an empty or single-item array stays an array.
    .PARAMETER Path
        The file to read, relative to the current location or absolute.
    .PARAMETER Description
        What the file holds, such as 'Workers'. Used in error messages.
    .EXAMPLE
        $workers = Read-JsonArray -Path .\Mocks\hris-workers.json -Description 'Workers'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Description = 'JSON'
    )

    # Resolve against the PowerShell location, not the .NET working directory, which can differ.
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

Export-ModuleMember -Function Read-JsonArray
