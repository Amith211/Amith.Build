#requires -Version 7.4
[CmdletBinding()]
param([string] $ConfigPath, [string] $Solution, [string] $RootPath,
      [ValidateSet('all','containers')][string] $BuildMode,
      [Alias('Project')][string[]] $ProjectPath, [string] $Version, [string[]] $Runtimes, [string[]] $Exclude, [hashtable[]] $Projects,
      [ValidateNotNullOrEmpty()][string[]] $PackProjects = @(), [ValidateNotNullOrEmpty()][string[]] $PackOnlyProjects = @(), [ValidateNotNullOrEmpty()][string[]] $ExcludePackProjects = @(),
          [switch] $PackAllLibraries, [switch] $NoPack,
          [switch] $SelfContained, [switch] $SingleFile, [switch] $StandaloneSingleFile,
          [switch] $VersionedArchives, [switch] $UnversionedArchives,
          [switch] $IncludeSymbols, [switch] $IncludeDevelopmentSettings, [string[]] $PackageExcludes = @(),
      [switch] $NoTests, [switch] $SkipTests,
      [string] $SdkVersion, [string[]] $AdditionalSdks = @(),
      [string] $PlanPath, [string] $ContainerBuilder, [string[]] $Stages, [switch] $PlanOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$plan = Invoke-AmithBuild @PSBoundParameters
$sdkExecution=if($plan.Contains('SdkExecution')){$plan.SdkExecution}else{$null}
& (Get-Module Amith.Build) {param($execution)Write-AmithSdkGitHubEnvironment $execution} $sdkExecution
Write-Host "Artifacts: $($plan.OutputRoot)"

if ($env:GITHUB_OUTPUT) {
    $buildMode = & (Get-Module Amith.Build) { param($p) Get-AmithValue $p 'BuildMode' 'all' } $plan
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "build_mode=$buildMode" -Encoding utf8
    $containers = @(& (Get-Module Amith.Build) { param($p) Get-AmithValue $p 'Containers' @() } $plan)
    $hasContainers = ($containers.Count -gt 0).ToString().ToLowerInvariant()
    $containerRelease = & (Get-Module Amith.Build) { param($p) (ConvertTo-AmithBoolean (Get-AmithValue (Get-AmithValue (Get-AmithValue $p 'Release' @{}) 'Containers' @{}) 'Enabled' $false)).ToString().ToLowerInvariant() } $plan
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "has_containers=$hasContainers" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "container_release=$containerRelease" -Encoding utf8
    if ($containers.Count) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "container_registry=$($containers[0].Registry)" -Encoding utf8 }
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "plan_path=$($plan.PlanPath)" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "output_root=$($plan.OutputRoot)" -Encoding utf8
    if ($plan.Contains('RetainedRoot')) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "retained_root=$($plan.RetainedRoot)" -Encoding utf8 }
}
