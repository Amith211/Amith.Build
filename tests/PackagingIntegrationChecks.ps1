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


Check 'cross-runtime publishing keeps a transitive executable reference on the requested runtime' {
    $root=Join-Path $testRoot 'runtime-reference-graph'
    foreach($directory in @('Client','Bridge','Api')){[void][IO.Directory]::CreateDirectory((Join-Path $root $directory))}
    Set-Content (Join-Path $root 'Directory.Build.props') @'
<Project>
  <PropertyGroup Condition="'$(TargetFramework)' != '' and !$(TargetFramework.Contains('-windows'))">
    <RuntimeIdentifier>linux-x64</RuntimeIdentifier>
  </PropertyGroup>
</Project>
'@
    Set-Content (Join-Path $root 'Client/Client.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0-windows</TargetFramework><OutputType>Exe</OutputType><SelfContained>true</SelfContained><PublishSingleFile>true</PublishSingleFile><RuntimeIdentifier>win-x64</RuntimeIdentifier></PropertyGroup>
  <ItemGroup><ProjectReference Include="../Bridge/Bridge.csproj" /></ItemGroup>
</Project>
'@
    Set-Content (Join-Path $root 'Bridge/Bridge.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
  <ItemGroup><ProjectReference Include="../Api/Api.csproj" /></ItemGroup>
</Project>
'@
    Set-Content (Join-Path $root 'Api/Api.csproj') @'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><SelfContained>true</SelfContained><PublishSingleFile>true</PublishSingleFile></PropertyGroup>
</Project>
'@
    Set-Content (Join-Path $root 'Client/Program.cs') 'System.Console.WriteLine(BridgeMarker.Value);'
    Set-Content (Join-Path $root 'Bridge/Bridge.cs') 'public static class BridgeMarker { public static string Value => ApiMarker.Value; }'
    Set-Content (Join-Path $root 'Api/Program.cs') 'System.Console.WriteLine("runtime fixture"); public static class ApiMarker { public static string Value => "runtime fixture"; }'
    # Force Linux RID inference on Windows too, making the cross-host regression
    # reproducible on both CI platforms without running a foreign executable.
    $projects=@(
        @{Path='Client/Client.csproj';Runtimes=@('win-x64');PublishArguments=@('-p:NETCoreSdkPortableRuntimeIdentifier=linux-x64')}
        @{Path='Api/Api.csproj';Runtimes=@('win-x64','linux-x64')}
    )
    $p=Invoke-AmithBuild -RootPath $root -Projects $projects -SdkVersion '10' -NoTests -Version '0.0.0-runtime-graph' -Stages Restore,Build,Publish,Archive
    foreach($target in @(
        @{Name='Client';Runtime='win-x64';Executable='Client.exe'},
        @{Name='Api';Runtime='win-x64';Executable='Api.exe'},
        @{Name='Api';Runtime='linux-x64';Executable='Api'}
    )){
        $artifact=@($p.Artifacts|Where-Object{$_.Kind -eq 'PublishDirectory' -and $_.Project -eq $target.Name -and $_.Runtime -eq $target.Runtime})
        Assert-Equal 1 $artifact.Count
        $executable=Join-Path $artifact[0].Path $target.Executable
        Assert-True (Test-Path $executable)
        $stream=[IO.File]::OpenRead($executable)
        try{
            $header=[byte[]]::new(4)
            Assert-Equal 4 $stream.Read($header,0,4)
            if($target.Runtime -like 'win-*'){Assert-Equal '4D-5A' ([BitConverter]::ToString($header,0,2))}
            else{Assert-Equal '7F-45-4C-46' ([BitConverter]::ToString($header))}
        }finally{$stream.Dispose()}
    }
    Assert-Equal 4 @($p.Artifacts|Where-Object Kind -eq Archive).Count
}
