#requires -Version 7.4
[CmdletBinding()]
param([string] $ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../src/Amith.Build/NuGet.ps1')
Initialize-AmithNuGetSources -SourcesJson $env:AMITH_NUGET_RESTORE_SOURCES -ConfigPath $ConfigPath
if (-not $ConfigPath) {
    Test-AmithNuGetEffectiveSources -SourcesJson $env:AMITH_NUGET_RESTORE_SOURCES -WorkingDirectory (Get-Location).ProviderPath
}
