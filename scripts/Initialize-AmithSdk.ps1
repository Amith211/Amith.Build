#requires -Version 7.4
[CmdletBinding()]
param([string]$RootPath=(Get-Location).ProviderPath,[string]$SdkVersion='auto',[string[]]$AdditionalSdks=@())
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$module=Get-Module Amith.Build
& $module {
    param($root,$version,$additional)
    $root=Resolve-AmithPath $root
    $scope=Open-AmithSdkScope $root $version $additional
    try{Write-AmithSdkGitHubEnvironment $scope.Execution}
    finally{Close-AmithSdkScope $scope}
} $RootPath $SdkVersion $AdditionalSdks
