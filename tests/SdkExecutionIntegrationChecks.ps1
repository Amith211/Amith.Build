Check 'real SDK execution selects the requested major and preserves source and caller environment' {
    $root=Join-Path $testRoot 'real-sdk-execution'
    [void][IO.Directory]::CreateDirectory($root)
    Set-Content (Join-Path $root 'App.csproj') '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>'
    Set-Content (Join-Path $root 'Program.cs') 'System.Console.WriteLine("Disposable build fixture");'
    $global=Join-Path $root 'global.json';Set-Content $global '{}' -NoNewline
    $beforePath=$env:PATH;$beforeRoot=$env:DOTNET_ROOT
    $p=Invoke-AmithBuild -RootPath $root -Version '0.0.0-sdk-test' -SdkVersion '10' -NoTests -Stages Restore,Build
    Assert-True $p.SdkExecution.Version.StartsWith('10.')
    Assert-Equal $beforePath $env:PATH;Assert-Equal $beforeRoot $env:DOTNET_ROOT
    Assert-Equal '{}' (Get-Content $global -Raw)
    Assert-Equal 1 @(Get-ChildItem (Join-Path $p.SdkExecution.Root 'sdk') -Directory).Count
    $marker=Join-Path $p.SdkExecution.Root '.amith-ready.json'
    $before=(Get-Item -Force $marker).LastWriteTimeUtc
    $p=Invoke-AmithBuildStage $p.PlanPath Build
    Assert-Equal $before (Get-Item -Force $marker).LastWriteTimeUtc
    Set-Content $global '{"test":{"runner":"VSTest"}}'
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Build} '*changed since planning*'
    Assert-Equal Failed (Read-Plan $p.PlanPath).Stages.Build.Status
    Assert-Equal $beforePath $env:PATH;Assert-Equal $beforeRoot $env:DOTNET_ROOT

    # The presence of a compatible policy does not require any override.
    $policy=@{sdk=@{version=$p.SdkExecution.Version;rollForward='disable'};test=@{runner='VSTest'}}|ConvertTo-Json -Depth 4
    Set-Content $global $policy -NoNewline
    $compatible=Invoke-AmithBuild -RootPath $root -Version '0.0.0-sdk-test' -SdkVersion '10' -NoTests -PlanOnly
    Assert-Equal $p.SdkExecution.Version $compatible.SdkExecution.Version
    Assert-Throws {Invoke-AmithBuild -RootPath $root -Version '0.0.0-sdk-test' -SdkVersion '11' -NoTests -PlanOnly} '*Cannot select*'
    Assert-Equal $policy (Get-Content $global -Raw)
    Assert-Equal $beforePath $env:PATH;Assert-Equal $beforeRoot $env:DOTNET_ROOT
}
Check 'SDK bootstrap script exports the selected host for subsequent workflow steps' {
    $root=Join-Path $testRoot 'sdk-bootstrap'
    [void][IO.Directory]::CreateDirectory($root)
    Set-Content (Join-Path $root 'global.json') '{}' -NoNewline
    $original=@{}
    foreach($name in @('GITHUB_ENV','GITHUB_PATH','GITHUB_OUTPUT')){$original[$name]=[Environment]::GetEnvironmentVariable($name)}
    try{
        $env:GITHUB_ENV=Join-Path $root 'environment'
        $env:GITHUB_PATH=Join-Path $root 'path'
        $env:GITHUB_OUTPUT=Join-Path $root 'outputs'
        $scriptPath=Join-Path $PSScriptRoot '../scripts/Initialize-AmithSdk.ps1'
        & $module {param($scriptPath,$root)Invoke-AmithNative pwsh @('-NoProfile','-File',$scriptPath,'-RootPath',$root,'-SdkVersion','10')} $scriptPath $root
        Assert-True ((Get-Content $env:GITHUB_ENV -Raw).Contains('DOTNET_ROOT='))
        Assert-True ((Get-Content $env:GITHUB_OUTPUT -Raw) -match 'sdk_version=10\.')
        Assert-True (Test-Path ((Get-Content $env:GITHUB_PATH -Raw).Trim()))
    }finally{
        foreach($name in $original.Keys){
            if($null -eq $original[$name]){[Environment]::SetEnvironmentVariable($name,[NullString]::Value)}
            else{[Environment]::SetEnvironmentVariable($name,$original[$name])}
        }
    }
}


Check 'selected SDK direct MSBuild evaluation matches CLI metadata and preserves consumer hooks' {
    $root=Join-Path $testRoot 'direct-metadata'
    [void][IO.Directory]::CreateDirectory($root)
    Set-Content (Join-Path $root 'global.json') '{"test":{"runner":"VSTest"}}'
    Set-Content (Join-Path $root 'consumer.targets') '<Project><PropertyGroup><AssemblyName>ImportedMetadataName</AssemblyName></PropertyGroup></Project>'
    Set-Content (Join-Path $root 'App.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><CustomAfterMicrosoftCommonTargets>$(MSBuildProjectDirectory)/consumer.targets</CustomAfterMicrosoftCommonTargets></PropertyGroup>
  <ItemGroup><PackageReference Include="Example.Metadata.Package" Version="1.2.3" /></ItemGroup>
</Project>
'@
    $project=Join-Path $root 'App.csproj'
    foreach($selector in @('10','11')){
        $scope=& $module {param($root,$selector)Open-AmithSdkScope $root $selector} $root $selector
        try{
            $cli=& $module {param($project)Get-AmithProjectMetadata $project Release '0.0.0-metadata'} $project
            $direct=& $module {param($project,$execution)Get-AmithProjectMetadata $project Release '0.0.0-metadata' $execution} $project $scope.Execution
            Assert-Equal $cli $direct
            Assert-Equal 'ImportedMetadataName' $direct.AssemblyName
            Assert-Equal @('Example.Metadata.Package') $direct.TestPackages
            Assert-Equal (Join-Path $root 'consumer.targets') $direct.CustomAfterMicrosoftCommonTargets.Replace('/',[IO.Path]::DirectorySeparatorChar)
        }finally{& $module {param($scope)Close-AmithSdkScope $scope} $scope}
    }
}
