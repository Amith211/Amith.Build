# Invoked while native build, test and release commands are mocked.
function New-TestFreePlan {
    param([switch]$NoTests,[switch]$SkipTests)
    New-AmithBuildPlan -ConfigPath $configPath -Project 'src/Api/Api.csproj' -NoTests:$NoTests -SkipTests:$SkipTests -Version 1.2.3 -PlanPath (Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.json'))
}
Check 'test policies default to required and CLI/config overrides preserve explicit false' {
    $p=New-FixturePlan
    Assert-True (-not $p.TestPolicy.NoTests);Assert-True (-not $p.TestPolicy.SkipTests)
    $config=Join-Path $fixture 'test-policy.psd1'
    Set-Content -LiteralPath $config -Value '@{Solution=''Fixture.sln'';SkipTests=$true}'
    $p=Invoke-AmithBuild -ConfigPath $config -Version 1.2.3 -PlanOnly
    Assert-True $p.TestPolicy.SkipTests
    $p=Invoke-AmithBuild -ConfigPath $config -Version 1.2.3 -SkipTests:$false -PlanOnly
    Assert-True (-not $p.TestPolicy.SkipTests)
    Set-Content -LiteralPath $config -Value '@{Discover=$false;Projects=@(''src/Api/Api.csproj'');NoTests=$true}'
    $p=Invoke-AmithBuild -ConfigPath $config -NoTests:$false -PlanOnly
    Assert-True (-not $p.TestPolicy.NoTests)
}
Check 'NoTests and SkipTests conflict only when both resolve to true' {
    Assert-Throws {New-TestFreePlan -NoTests -SkipTests} '*mutually exclusive*'
    $config=Join-Path $fixture 'conflicting-test-policy.psd1'
    Set-Content -LiteralPath $config -Value '@{Solution=''Fixture.sln'';NoTests=$true;SkipTests=$true}'
    Assert-Throws {New-AmithBuildPlan -ConfigPath $config} '*mutually exclusive*'
    $p=New-TestFreePlan -NoTests -SkipTests:$false
    Assert-True $p.TestPolicy.NoTests
}
Check 'NoTests fails when selected test projects exist even if the host cannot run them' {
    Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -NoTests} '*contains test projects*'
    $other=if($IsWindows){'Linux'}else{'Windows'}
    Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -NoTests -Projects @(@{Path='tests/Api.Tests/Api.Tests.csproj';TestPlatforms=@($other)})} '*contains test projects*'
}
Check 'default Test fails with actionable guidance when no test projects are selected' {
    $p=New-TestFreePlan
    foreach($stage in @('Restore','Build')) {$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Test} '*No test projects*NoTests*SkipTests*'
    $p=Read-Plan $p.PlanPath
    Assert-Equal Failed $p.Stages.Test.Status;Assert-Equal 0 $p.TestResults.ExecutedTargets
    Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*successful Test*'
}
Check 'default Test fails when all selected tests are incompatible with this host' {
    $other=if($IsWindows){'Linux'}else{'Windows'}
    $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='tests/Api.Tests/Api.Tests.csproj';TestPlatforms=@($other)}) -PlanPath (Join-Path $testRoot 'incompatible-tests.json')
    foreach($stage in @('Restore','Build')) {$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Test} '*No test targets can run*compatible runner*SkipTests*'
    Assert-Equal @('Api.Tests') (Read-Plan $p.PlanPath).TestResults.SkippedProjects
}
Check 'NoTests records the declaration and satisfies the release test gate without test invocations' {
    $p=New-TestFreePlan -NoTests;$state.Calls.Clear()
    foreach($stage in @('Restore','Build','Test')) {$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    Assert-Equal NoTests $p.TestResults.Disposition
    Assert-Equal 0 $p.TestResults.ExecutedTargets
    Assert-Equal 0 @($state.Calls|Where-Object {$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'test'}).Count
    & $module {param($p)Assert-AmithReleaseArtifacts $p} $p
    $p.Projects+=@(@{Name='Stale.Tests';Kind='Test'})
    Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*contains test projects*'
}
Check 'SkipTests is persisted and permits explicit release while normal test execution is bypassed' {
    $p=New-AmithBuildPlan -ConfigPath $configPath -Version 1.2.3 -SkipTests -PlanPath (Join-Path $testRoot 'skip-tests-release.json')
    $p.Release=@{RequireTestExecution=$true;NuGet=@{Enabled=$true;SourceEnvironment='AMITH_TEST_FEED';ApiKeyEnvironment='AMITH_TEST_KEY'}}
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    $oldFeed=$env:AMITH_TEST_FEED;$oldKey=$env:AMITH_TEST_KEY
    $env:AMITH_TEST_FEED='https://example.invalid/nuget';$env:AMITH_TEST_KEY='not-a-real-key'
    try {
        $state.Calls.Clear()
        foreach($stage in @('Restore','Build','Test','Pack','Release')) {$p=Invoke-AmithBuild -PlanPath $p.PlanPath -Stages $stage}
    } finally {$env:AMITH_TEST_FEED=$oldFeed;$env:AMITH_TEST_KEY=$oldKey}
    Assert-Equal Skipped $p.TestResults.Disposition;Assert-Equal @('Api.Tests') $p.TestResults.SkippedProjects
    Assert-Equal 0 @($state.Calls|Where-Object {$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'test'}).Count
    Assert-Equal 1 @($state.Calls|Where-Object {$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'nuget'}).Count
}
Check 'a bypass flag alone cannot replace a recorded successful Test stage' {
    $p=New-TestFreePlan -NoTests
    $p.Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'}}
    Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*bypass has not been recorded*'
    $p.TestPolicy=@{NoTests=$false;SkipTests=$true}
    Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*bypass has not been recorded*'
}
Check 'old saved plans default to required testing and cannot release zero-target results' {
    $p=New-FixturePlan;[void]$p.Remove('TestPolicy')
    $p.Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'}}
    $p.TestResults=@{ExecutedTargets=0}
    Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*at least one executed test target*'
    $p.TestResults.ExecutedTargets=1
    & $module {param($p)Assert-AmithReleaseArtifacts $p} $p
}
Check 'rebuilding clears earlier test results including an intentional bypass' {
    $p=New-TestFreePlan -SkipTests
    foreach($stage in @('Restore','Build','Test')) {$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    $p=Invoke-AmithBuildStage $p.PlanPath Build
    Assert-True (-not $p.Contains('TestResults'));Assert-True (-not $p.Stages.Contains('Test'))
}

Check 'a failed test command invalidates an earlier result and blocks release' {
    $p=New-FixturePlan
    foreach($stage in @('Restore','Build','Test')) {$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    $p.Stages.Release=@{Status='Succeeded'}
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    $state.FailTest=$true
    try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Test} '*simulated test failure*'}
    finally {$state.FailTest=$false}
    $p=Read-Plan $p.PlanPath
    Assert-Equal Failed $p.Stages.Test.Status
    Assert-Equal 0 $p.TestResults.ExecutedTargets
    Assert-True (-not $p.Stages.Contains('Release'))
    Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*successful Test*'
}
Check 'SkipTests can explicitly bypass a plan containing no test projects' {
    $p=New-TestFreePlan -SkipTests
    foreach($stage in @('Restore','Build','Test')) {$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    Assert-Equal Skipped $p.TestResults.Disposition
    Assert-Equal 0 $p.TestResults.SkippedProjects.Count
    & $module {param($p)Assert-AmithReleaseArtifacts $p} $p
}
