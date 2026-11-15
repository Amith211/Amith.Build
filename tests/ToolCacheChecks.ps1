# Invoked while native tooling is mocked; cache location is an isolated test directory.
Check 'Velopack cache is reused across plans and repairs incomplete installs' {
    $p=New-VelopackFixture
    $project=@($p.Projects|Where-Object Name -eq Desktop)[0]
    $state.Calls.Clear()
    $first=& $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project
    $state.Calls.Clear()
    $second=& $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project
    Assert-Equal $first $second
    Assert-Equal 0 @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments -contains 'install'}).Count
    Assert-True (-not $first.StartsWith($p.OutputRoot))
    Set-Content -LiteralPath $first -Value 'corrupted executable'
    $state.Calls.Clear()
    $null=& $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project
    Assert-Equal 1 @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments -contains 'install'}).Count
    Remove-Item -Force -LiteralPath (Join-Path (Split-Path $first) '.amith-ready.json')
    $state.Calls.Clear()
    $null=& $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project
    Assert-Equal 1 @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments -contains 'install'}).Count
}
Check 'failed Velopack install is not reused on retry' {
    $p=New-VelopackFixture
    $project=@($p.Projects|Where-Object Name -eq Desktop)[0]
    $project.Velopack.ToolVersion='1.2.160'
    $state.FailToolInstall=$true
    try {
        Assert-Throws { & $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project } '*simulated tool install failure*'
    } finally { $state.FailToolInstall=$false }
    $state.Calls.Clear()
    $file=& $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project
    Assert-True (Test-Path -LiteralPath $file)
    Assert-Equal 1 @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments -contains 'install'}).Count
}
Check 'restored Velopack dependency still selects the cached matching tool' {
    $p=New-VelopackFixture
    $project=@($p.Projects|Where-Object Name -eq Desktop)[0]
    $project.Velopack.Remove('ToolVersion')
    $assets=Join-Path $testRoot 'tool-assets.json'
    Set-Content -LiteralPath $assets -Value '{"libraries":{"Velopack/1.2.159":{}}}'
    $project.ProjectAssetsFile=$assets
    $state.Calls.Clear()
    $file=& $module {param($p,$project)Get-AmithVelopackTool $p $project} $p $project
    Assert-True $file.Contains('1.2.159')
    Assert-Equal '1.2.159' @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments -contains 'install'})[0].Arguments[4]
}
