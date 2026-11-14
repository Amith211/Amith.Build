# Real SDK publish checks; only this generated fixture is executed.
Check 'development content is removed before bundling and custom publish output uses shared package rules' {
    $root=Join-Path $testRoot 'publish-policy'
    foreach($dir in @('App','Lib')){[void][IO.Directory]::CreateDirectory((Join-Path $root $dir))}
    $hook=Join-Path $root 'consumer.targets'
    Set-Content -LiteralPath $hook -Value @'
<Project>
  <Target Name="ConsumerPublishCopy" AfterTargets="Publish">
    <WriteLinesToFile File="$(PublishDir)custom-hook.txt" Lines="consumer hook preserved" Overwrite="true" />
    <WriteLinesToFile File="$(PublishDir)late.Development.json" Lines="late content" Overwrite="true" />
  </Target>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $root 'Lib/Lib.csproj') -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
  <ItemGroup>
    <None Update="transitive.Development.json" CopyToOutputDirectory="Always" CopyToPublishDirectory="Always" ExcludeFromSingleFile="false" />
  </ItemGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $root 'App/App.csproj') -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><CustomAfterMicrosoftCommonTargets>$hook</CustomAfterMicrosoftCommonTargets></PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../Lib/Lib.csproj" />
    <None Update="*.json" CopyToOutputDirectory="Always" CopyToPublishDirectory="Always" ExcludeFromSingleFile="false" />
  </ItemGroup>
</Project>
"@
    Set-Content -LiteralPath (Join-Path $root 'App/Program.cs') -Value @'
using System;
using System.IO;
Console.WriteLine($"main={File.Exists(Path.Combine(AppContext.BaseDirectory,"appsettings.Development.json"))};transitive={File.Exists(Path.Combine(AppContext.BaseDirectory,"transitive.Development.json"))};normal={File.Exists(Path.Combine(AppContext.BaseDirectory,"appsettings.json"))};mixed={File.Exists(Path.Combine(AppContext.BaseDirectory,"Development.JSON"))}");
'@
    Set-Content -LiteralPath (Join-Path $root 'Lib/transitive.Development.json') -Value '{"fixture":true}'
    foreach($name in @('appsettings.Development.json','Development.JSON','appsettings.json','swagger.json')) {Set-Content -LiteralPath (Join-Path $root "App/$name") -Value '{"fixture":true}'}
    $rid=[Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
    $config=Join-Path $root 'amith.build.psd1'
    Set-Content -LiteralPath $config -Value "@{Discover=`$false;Projects=@(@{Path='App/App.csproj';Runtimes=@('$rid');SelfContained=`$false;SingleFile=`$true;SelfExtract=`$true})}"
    foreach($include in @($false,$true)) {
        $p=Invoke-AmithBuild -ConfigPath $config -Version '0.0.0-policy-test' -IncludeDevelopmentSettings:$include -Stages Restore,Build,Publish,Archive
        $publish=@($p.Artifacts|Where-Object Kind -eq PublishDirectory)[0]
        Assert-Equal $hook $p.Projects[0].OriginalPublishHook
        Assert-True (Test-Path -LiteralPath (Join-Path $publish.Path 'custom-hook.txt'))
        Assert-True (Test-Path -LiteralPath (Join-Path $publish.Path 'late.Development.json'))
        $prepared=$p.PackageInputs["App|$rid"]
        Assert-Equal $include (Test-Path -LiteralPath (Join-Path $prepared.Directory 'late.Development.json'))
        $exe=Join-Path $prepared.Directory $(if($IsWindows){'App.exe'}else{'App'})
        $oldExtract=$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR
        try {
            $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=Join-Path $root ([guid]::NewGuid().ToString('N'))
            $result=@(& $module {param($exe,$directory)Invoke-AmithNative $exe @() $directory -Capture} $exe $prepared.Directory)
        } finally {$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=$oldExtract}
        Assert-Equal @("main=$include;transitive=$include;normal=True;mixed=$include") $result
        $zip=[IO.Compression.ZipFile]::OpenRead(@($p.Artifacts|Where-Object Kind -eq Archive)[0].Path)
        try {
            Assert-True ($zip.Entries.FullName -contains 'custom-hook.txt')
            Assert-Equal $include ($zip.Entries.FullName -contains 'late.Development.json')
            Assert-True ($zip.Entries.FullName -contains 'App.pdb')
        } finally {$zip.Dispose()}
    }
}
