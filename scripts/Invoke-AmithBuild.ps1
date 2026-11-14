#requires -Version 7.4
[CmdletBinding()]
param([string] $ConfigPath, [string] $Solution, [string] $RootPath,
      [Alias('Project')][string[]] $ProjectPath, [string] $Version, [string[]] $Runtimes, [string[]] $Exclude, [hashtable[]] $Projects,
      [ValidateNotNullOrEmpty()][string[]] $PackProjects = @(), [ValidateNotNullOrEmpty()][string[]] $PackOnlyProjects = @(), [ValidateNotNullOrEmpty()][string[]] $ExcludePackProjects = @(),
          [switch] $PackAllLibraries, [switch] $NoPack,
          [switch] $SelfContained, [switch] $SingleFile, [switch] $StandaloneSingleFile,
          [switch] $VersionedArchives, [switch] $UnversionedArchives,
          [switch] $IncludeSymbols, [switch] $IncludeDevelopmentSettings, [string[]] $PackageExcludes = @(),
      [string] $PlanPath, [string[]] $Stages, [switch] $PlanOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$plan = Invoke-AmithBuild @PSBoundParameters
Write-Host "Artifacts: $($plan.OutputRoot)"

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "plan_path=$($plan.PlanPath)" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "output_root=$($plan.OutputRoot)" -Encoding utf8
    if ($plan.Contains('RetainedRoot')) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "retained_root=$($plan.RetainedRoot)" -Encoding utf8 }
}
