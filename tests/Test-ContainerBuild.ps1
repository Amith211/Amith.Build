#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $ContainerBuilder)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$module = Get-Module Amith.Build
$root = Join-Path ([IO.Path]::GetTempPath()) ('amith-container-integration-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
[IO.File]::WriteAllText((Join-Path $root 'Dockerfile'),"FROM scratch`nCOPY payload.txt /payload.txt`n")
[IO.File]::WriteAllText((Join-Path $root 'payload.txt'),'Amith.Build OCI integration')
$containers = @(& $module {param($r)Get-AmithContainerPlans @{Containers=@(@{Name='scratch';Image='example.invalid/tests/scratch';Platforms=@('linux/amd64','linux/arm64')})} $r '1.2.3'} $root)
$plan = @{
    SchemaVersion='1alpha1';Root=$root;Version='1.2.3';SourceCommit='fixture';Projects=@()
    Containers=$containers;Artifacts=@();OutputRoot=(Join-Path $root 'output');PlanPath=(Join-Path $root 'plan.json')
    Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'}}
    TestPolicy=@{NoTests=$true;SkipTests=$false};TestResults=@{Disposition='NoTests';ExecutedTargets=0}
}
& $module {param($p)Write-AmithJson $p $p.PlanPath} $plan
$plan = Invoke-AmithBuildStage $plan.PlanPath Container -ContainerBuilder $ContainerBuilder
if ($plan.Artifacts.Count -ne 1 -or $plan.Artifacts[0].Platforms.Count -ne 2) { throw 'Multi-platform OCI export did not produce the expected image.' }
$plan = Invoke-AmithBuildStage $plan.PlanPath Retain
$files = @(Get-ChildItem -LiteralPath $plan.RetainedRoot -Recurse -File)
if ($files.Count -ne 1 -or (Get-FileHash -LiteralPath $files[0].FullName -Algorithm SHA256).Hash -cne $plan.Artifacts[0].SHA256) { throw 'Real container artifact retention failed.' }
Write-Host "PASS real multi-platform OCI export and retention: $($plan.Artifacts[0].Digest)"
Write-Host "Integration plan: $($plan.PlanPath)"

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "archive_path=$($plan.Artifacts[0].Path)" -Encoding utf8
}
