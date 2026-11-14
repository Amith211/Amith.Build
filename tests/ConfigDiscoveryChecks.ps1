# Uses the existing mocked MSBuild discovery; no consumer builds are executed.
function New-ConfigSearchFixture {
    $root=Join-Path $testRoot ('config-search-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    Set-Content -LiteralPath (Join-Path $root 'Api.csproj') -Value '<Project />'
    return $root
}
function Write-SearchConfig($Root,$RelativePath,$Text) {
    $path=Join-Path $Root $RelativePath
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    Set-Content -LiteralPath $path -Value $Text
}
Check 'automatic build-folder configs override root without merging and keep repository-relative paths' {
    foreach($folder in @('build','Build')) {
        $root=New-ConfigSearchFixture
        Write-SearchConfig $root 'amith.build.psd1' '@{Defaults=@{Name=''RootIgnored'';IncludeSymbols=$false}}'
        Write-SearchConfig $root "$folder/amith.build.psd1" '@{Discover=$false;Projects=@(''Api.csproj'');Defaults=@{Name=''BuildSelected''}}'
        $output=@(New-AmithBuildPlan -RootPath $root -Version 1.2.3 6>&1)
        $p=$output[-1]
        Assert-Equal $root $p.Root
        Assert-Equal BuildSelected $p.Projects[0].Name
        Assert-True $p.Projects[0].IncludeSymbols
        Assert-True (($output|Out-String).Contains((Join-Path $root "$folder/amith.build.psd1")))
        Assert-Equal (Join-Path $root '.amith-build/plan.json') $p.PlanPath
        Assert-Equal (Join-Path $root 'artifacts') $p.OutputBase
    }
}
Check 'automatic lookup falls back to root config then ordinary defaults' {
    $root=New-ConfigSearchFixture
    $p=New-AmithBuildPlan -RootPath $root
    Assert-Equal Api $p.Projects[0].Name
    Write-SearchConfig $root 'amith.build.psd1' '@{Defaults=@{Name=''RootSelected''}}'
    $p=New-AmithBuildPlan -RootPath $root
    Assert-Equal RootSelected $p.Projects[0].Name
}
Check 'explicit config wins and retains config-relative root semantics' {
    $root=New-ConfigSearchFixture
    Write-SearchConfig $root 'build/amith.build.psd1' '@{Defaults=@{Name=''AutomaticIgnored''}}'
    Write-SearchConfig $root 'custom/chosen.psd1' '@{Discover=$false;Projects=@(''Api.csproj'');Defaults=@{Name=''ExplicitSelected''}}'
    Set-Content -LiteralPath (Join-Path $root 'custom/Api.csproj') -Value '<Project />'
    $p=New-AmithBuildPlan -RootPath $root -ConfigPath 'custom/chosen.psd1'
    Assert-Equal (Join-Path $root 'custom') $p.Root
    Assert-Equal ExplicitSelected $p.Projects[0].Name
    Assert-Throws {New-AmithBuildPlan -RootPath $root -ConfigPath 'missing.psd1'} '*Configuration file not found*'
}
Check 'explicit Root overrides automatic and manually supplied config roots relative to the config directory' {
    $root=New-ConfigSearchFixture
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'other'))
    Set-Content -LiteralPath (Join-Path $root 'other/Api.csproj') -Value '<Project />'
    Write-SearchConfig $root 'build/amith.build.psd1' '@{Root=''../other'';Discover=$false;Projects=@(''Api.csproj'')}'
    foreach($mode in @('automatic','explicit')) {
        $arguments=@{RootPath=$root}
        if($mode -eq 'explicit') {$arguments.ConfigPath='build/amith.build.psd1'}
        $p=New-AmithBuildPlan @arguments
        Assert-Equal (Join-Path $root 'other') $p.Root
    }
}
Check 'config lookup does not search parents nested folders or the supplied solution directory' {
    $root=New-ConfigSearchFixture
    Write-SearchConfig $root 'amith.build.psd1' '@{Defaults=@{Name=''ParentMustNotLoad''}}'
    $child=Join-Path $root 'child';[void][IO.Directory]::CreateDirectory($child)
    Set-Content -LiteralPath (Join-Path $child 'Api.csproj') -Value '<Project />'
    Write-SearchConfig $child 'nested/amith.build.psd1' '@{Defaults=@{Name=''NestedMustNotLoad''}}'
    $p=New-AmithBuildPlan -RootPath $child
    Assert-Equal Api $p.Projects[0].Name
    # The fake solution returns the main fixture's project list.
    $p=New-AmithBuildPlan -RootPath $child -Solution (Join-Path $fixture 'Fixture.sln')
    Assert-True (@($p.Projects|Where-Object Name -eq Api).Count -eq 1)
}
if(-not $IsWindows) {
    Check 'distinct build and Build configs fail automatically but explicit selection resolves ambiguity' {
        $root=New-ConfigSearchFixture
        Write-SearchConfig $root 'build/amith.build.psd1' '@{Root=''..'';Defaults=@{Name=''LowerSelected''}}'
        Write-SearchConfig $root 'Build/amith.build.psd1' '@{Root=''..'';Defaults=@{Name=''UpperSelected''}}'
        Write-SearchConfig $root 'amith.build.psd1' '@{Defaults=@{Name=''RootIgnored''}}'
        Assert-Throws {New-AmithBuildPlan -RootPath $root} '*Ambiguous configuration*'
        $p=New-AmithBuildPlan -RootPath $root -ConfigPath 'Build/amith.build.psd1'
        Assert-Equal UpperSelected $p.Projects[0].Name
    }
}
