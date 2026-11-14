Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in @('Common.ps1', 'Discovery.ps1', 'Packaging.ps1', 'Stages.ps1', 'Velopack.ps1', 'Release.ps1', 'Public.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}
Export-ModuleMember -Function New-AmithBuildPlan, Invoke-AmithBuild, Invoke-AmithBuildStage
