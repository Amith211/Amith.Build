$selectionConfig = Join-Path $fixture 'build-selection.psd1'
$selectionTemplate = @'
@{
    Solution = 'Fixture.sln'
    Exclude = @('samples/**')
    Projects = @('tests/Cold.Tests/Cold.Tests.csproj')
    TestSuites = @{
        Backend = @('tests/Api.Tests/Api.Tests.csproj')
        Ui = @('tests/Cold.Tests/Cold.Tests.csproj')
    }
    Containers = @(
        @{Name='api'; Image='harbor.example.com/project/api'; TestSuites=@('Backend')}
        @{Name='worker'; Image='harbor.example.com/project/worker'; TestSuites=@('Backend')}
    )
    Release = @{GitHub=@{Enabled=$true}; NuGet=@{Enabled=$true}; Containers=@{Enabled=$true}}
}
'@
Set-Content -LiteralPath (Join-Path $fixture 'Dockerfile') -Value 'FROM scratch'
function New-SelectionPlan([string]$Mode='all', [string]$Text=$selectionTemplate) {
    Set-Content -LiteralPath $selectionConfig -Value $Text
    New-AmithBuildPlan -ConfigPath $selectionConfig -BuildMode $Mode -Version 1.2.3 -PlanPath (Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.json'))
}
Check 'full plans retain normal discovery and every test regardless of container suite mapping' {
    $p=New-SelectionPlan
    Assert-Equal all $p.BuildMode
    Assert-Equal @('Api.Tests','Cold.Tests') @($p.Projects | Where-Object Kind -eq Test | ForEach-Object Name | Sort-Object)
    Assert-True (@($p.Projects | Where-Object Name -eq Desktop).Count -eq 1)
}
Check 'containers mode evaluates only mapped test roots and deduplicates overlapping suites' {
    $state.Calls.Clear()
    $p=New-SelectionPlan containers
    Assert-Equal containers (Read-Plan $p.PlanPath).BuildMode
    Assert-Equal @('Api.Tests') @($p.Projects | ForEach-Object Name)
    Assert-Equal 0 @($state.Calls | Where-Object { $_.Arguments[0] -eq 'sln' }).Count
    Assert-Equal 0 @($state.Calls | Where-Object { ($_.Arguments -join ' ') -match 'Desktop.csproj|Cold.Tests.csproj' }).Count
    $state.Calls.Clear()
    foreach($stage in @('Restore','Build','Test','Pack','Publish','Archive','Installer')) { $p=Invoke-AmithBuildStage $p.PlanPath $stage }
    Assert-Equal 1 $p.TestResults.ExecutedTargets
    Assert-Equal 0 $p.Artifacts.Count
    Assert-Equal 0 @($state.Calls | Where-Object { $_.Arguments[0] -in @('pack','publish') -or $_.File -eq 'vpk' }).Count
    Assert-Equal 1 @($state.Calls | Where-Object { $_.Arguments[0] -eq 'build' }).Count
}
Check 'container-only Release ignores enabled GitHub and NuGet destinations and preserves test gates' {
    $p=New-SelectionPlan containers
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*successful Build*'
    foreach($stage in @('Restore','Build','Test')) { $p=Invoke-AmithBuildStage $p.PlanPath $stage }
    & $module {
        param($p)
        $original=(Get-Item Function:Invoke-AmithContainerRelease).ScriptBlock
        try {
            $script:SelectedContainerRelease=$false
            function script:Invoke-AmithContainerRelease {param($Plan,$Options) $script:SelectedContainerRelease=$true}
            Invoke-AmithRelease $p
            if (-not $script:SelectedContainerRelease) { throw 'Container publisher did not run' }
        } finally { Set-Item Function:script:Invoke-AmithContainerRelease $original }
    } $p
}
Check 'missing unknown and empty container suite selections fail planning' {
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace("TestSuites=@('Backend')",'TestSuites=@()'))} '*needs TestSuites*'
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace("TestSuites=@('Backend')","TestSuites=@('Missing')"))} '*Unknown test suite*'
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace("Backend = @('tests/Api.Tests/Api.Tests.csproj')",'Backend = @()'))} '*empty test selection*'
}
Check 'suite paths must be existing in-repository project paths and evaluate as tests' {
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace('tests/Api.Tests/Api.Tests.csproj','tests/Missing.csproj'))} '*does not exist*'
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace('tests/Api.Tests/Api.Tests.csproj','../outside.csproj'))} '*inside the repository*'
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace('tests/Api.Tests/Api.Tests.csproj','src/Api/Api.csproj'))} '*non-test project*'
    Assert-Throws {New-SelectionPlan containers ($selectionTemplate.Replace("Exclude = @('samples/**')","Exclude = @('samples/**','tests/Api.Tests/**')"))} '*excluded from the plan*'
}
Check 'test-free container plans require and record an explicit bypass' {
    $text=$selectionTemplate.Replace("TestSuites=@('Backend')",'TestSuites=@()')
    foreach($policy in @('NoTests','SkipTests')) {
        $p=New-SelectionPlan containers ($text.Replace("Solution = 'Fixture.sln'", "$policy = `$true; Solution = 'Fixture.sln'"))
        Assert-Equal 0 $p.Projects.Count
        foreach($stage in @('Restore','Build','Test')) { $p=Invoke-AmithBuildStage $p.PlanPath $stage }
        Assert-Equal $(if($policy -eq 'NoTests'){'NoTests'}else{'Skipped'}) $p.TestResults.Disposition
    }
}
Check 'container mode rejects missing containers and unrelated explicit project selections' {
    Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -BuildMode containers -Version 1.2.3} '*at least one configured container*'
    Set-Content -LiteralPath $selectionConfig -Value $selectionTemplate
    Assert-Throws {New-AmithBuildPlan -ConfigPath $selectionConfig -BuildMode containers -Project src/Api/Api.csproj -Version 1.2.3} '*cannot be combined*'
}
Check 'configuration mode is overridable and saved mode is validated on reload' {
    Set-Content -LiteralPath $selectionConfig -Value ($selectionTemplate.Replace("Solution = 'Fixture.sln'", "BuildMode='containers'; Solution = 'Fixture.sln'"))
    $p=New-AmithBuildPlan -ConfigPath $selectionConfig -Version 1.2.3 -PlanPath (Join-Path $testRoot 'configured-selection.json')
    Assert-Equal containers $p.BuildMode
    $p=Invoke-AmithBuild -ConfigPath $selectionConfig -BuildMode all -Version 1.2.3 -PlanOnly -PlanPath $p.PlanPath
    Assert-Equal all $p.BuildMode
    $p.BuildMode='invalid'; & $module {param($p) Write-AmithJson $p $p.PlanPath} $p
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Restore} '*Saved BuildMode*'
}
