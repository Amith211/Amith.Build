#requires -Version 7.4
[CmdletBinding()]
param([string]$SdkVersion='auto',[string[]]$AdditionalSdks=@(),
      [string[]]$TargetFrameworks=@(),[string]$RootPath=(Get-Location).ProviderPath,
      [string]$OutputPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$arguments=@{SdkVersion=$SdkVersion;AdditionalSdks=$AdditionalSdks;TargetFrameworks=$TargetFrameworks;RootPath=$RootPath}
$result=Resolve-AmithSdkRequirements @arguments
$json=$result | ConvertTo-Json -Depth 30
if($OutputPath){Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8}
$json
