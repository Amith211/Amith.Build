#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $ArchivePath, [Parameter(Mandatory)][string] $Registry)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$module=Get-Module Amith.Build
$root=Split-Path -Parent ([IO.Path]::GetFullPath($ArchivePath))
$image=& $module {param($path)Read-AmithOciArchive $path @('linux/amd64','linux/arm64')} $ArchivePath
$container=@{Name='scratch';Image="$Registry/amith-test/scratch";Tag='1.2.3';Platforms=@('linux/amd64','linux/arm64')}
$plan=@{
    SchemaVersion='1alpha1';Root=$root;OutputRoot=$root;Version='1.2.3';ExplicitVersion=$true;SourceCommit='fixture';Projects=@()
    PlanPath=(Join-Path $root 'registry-plan.json');Containers=@($container)
    Artifacts=@(@{Kind='ContainerArchive';Project='scratch';Path=$ArchivePath;SHA256=(Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash;Image=$container.Image;Tag='1.2.3';SourceCommit='fixture';Digest=$image.Digest;Platforms=$image.Platforms})
    Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'};Container=@{Status='Succeeded'}}
    TestPolicy=@{NoTests=$true;SkipTests=$false};TestResults=@{Disposition='NoTests';ExecutedTargets=0}
    Release=@{Containers=@{Enabled=$true;TagAsLatest=$true}}
}
& $module {param($p)Write-AmithJson $p $p.PlanPath} $plan
$plan=Invoke-AmithBuildStage $plan.PlanPath Release
if($plan.ContainerPublications.Count -ne 2 -or @($plan.ContainerPublications|Where-Object Digest -cne $image.Digest).Count){throw 'Registry publication did not preserve the image digest for both tags.'}
$plan=Invoke-AmithBuildStage $plan.PlanPath Release
if($plan.ContainerPublications.Count -ne 2){throw 'Registry retry was not idempotent.'}
Write-Host "PASS real registry publication, latest and idempotent retry: $($image.Digest)"
