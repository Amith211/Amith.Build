# Public NuGet tooling only; no consumer repository or release is contacted.
Check 'real Velopack installation is reusable outside the build output' {
    $root=Join-Path $testRoot 'real tool cache'
    [void][IO.Directory]::CreateDirectory($root)
    Set-Content -LiteralPath (Join-Path $root 'nuget.config') -Value '<configuration><packageSources><clear/><add key="nuget.org" value="https://api.nuget.org/v3/index.json"/></packageSources></configuration>'
    $original=$env:AMITH_TOOL_CACHE
    try {
        $env:AMITH_TOOL_CACHE=Join-Path $root 'tools'
        $plan=@{Root=$root}
        $tool=& $module {param($p)Install-AmithCachedVelopack '1.2.161' $p} $plan
        $again=& $module {param($p)Install-AmithCachedVelopack '1.2.161' $p} $plan
        Assert-Equal $tool $again
        Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path $tool) '.amith-ready.json'))
        $version=@(& $tool --skip-updates --help) -join ''
        Assert-Equal 0 $LASTEXITCODE
        Assert-True $version.Contains('1.2.161')
    } finally { $env:AMITH_TOOL_CACHE=$original }
}
