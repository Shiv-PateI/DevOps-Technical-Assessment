<#
.SYNOPSIS
    Reading and writing the identity sync's JSON files.

.DESCRIPTION
    File handling shared by the identity sync scripts, kept apart from the
    decision rules and the terminal output.

    Public functions:
      Read-JsonArray    Reads a JSON file that holds an array, with clear
                        errors when the file is missing or not valid JSON.
      Read-JsonFile     Reads a JSON file that holds one object, returning
                        nothing when the file does not exist yet.
      Write-JsonFile    Writes an object to a JSON file safely: to a
                        temporary file first, then moved into place, so a
                        crash part-way never leaves a half-written file.
#>

Set-StrictMode -Version Latest

# Resolves a path against the PowerShell location, not the .NET working directory, which can differ.
function Resolve-FullPath {
    param([string] $Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

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
        $workers = Read-JsonArray -Path .\Mocks\HRIS-Workers.json -Description 'Workers'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Description = 'JSON'
    )

    $fullPath = Resolve-FullPath $Path
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

function Read-JsonFile {
    <#
    .SYNOPSIS
        Reads a JSON file holding one object. Returns nothing if the file does not exist.
    .DESCRIPTION
        Used for files the sync creates itself, such as its state file, which
        will not exist on the first run. A file that exists but is not valid
        JSON is an error, so a damaged state file is never silently ignored.
    .EXAMPLE
        $state = Read-JsonFile -Path .\State\sync-state.json -Description 'Sync state'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Description = 'JSON'
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-Path -Path $fullPath -PathType Leaf)) { return }

    try {
        ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($fullPath))
    }
    catch {
        throw "$Description file is not valid JSON: $fullPath. $($_.Exception.Message)"
    }
}

function Write-JsonFile {
    <#
    .SYNOPSIS
        Writes an object to a JSON file, safely.
    .DESCRIPTION
        Writes to a temporary file in the same folder, then moves it over the
        real file, so a reader or a crash never sees a half-written file. The
        folder is created if missing. UTF-8 without a BOM, so other JSON
        parsers read it cleanly on any PowerShell version.
    .EXAMPLE
        Write-JsonFile -Path .\State\sync-state.json -InputObject $state
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $InputObject,
        [int] $Depth = 10
    )

    $fullPath  = Resolve-FullPath $Path
    $directory = Split-Path -Path $fullPath -Parent
    if (-not (Test-Path -Path $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $json     = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    $tempPath = '{0}.tmp' -f $fullPath
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tempPath -Destination $fullPath -Force
}

Export-ModuleMember -Function Read-JsonArray, Read-JsonFile, Write-JsonFile
