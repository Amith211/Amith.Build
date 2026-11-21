#requires -Version 7.4
[CmdletBinding()]
param([switch] $Integration)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$module = Get-Module Amith.Build
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Amith.Build.Tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$originalToolCache = $env:AMITH_TOOL_CACHE
$env:AMITH_TOOL_CACHE = Join-Path $testRoot 'tool cache'
$script:passed = 0
function Check([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Host "PASS $Name" }
function Assert-True($Value) { if (-not $Value) { throw 'Assertion failed' } }
function Assert-Equal($Expected, $Actual) {
    if ((ConvertTo-Json -InputObject $Expected -Compress -Depth 20) -cne (ConvertTo-Json -InputObject $Actual -Compress -Depth 20)) { throw "Expected '$Expected', got '$Actual'" }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern = '*') {
    $caught = $false
    try { & $Body | Out-Null } catch { if ($_.Exception.Message -notlike $Pattern) { throw }; $caught = $true }
    if (-not $caught) { throw 'Expected operation to fail.' }
}
function Read-Plan($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 60 }
Check 'all PowerShell source parses' {
    foreach ($file in @(Get-ChildItem (Join-Path $PSScriptRoot '../src'),(Join-Path $PSScriptRoot '../scripts') -Recurse -File | Where-Object Extension -in '.ps1','.psm1','.psd1')) {
        $tokens=$null; $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors); Assert-Equal 0 $errors.Count
    }
}
Check 'timing logs preserve successful output and stay on the information stream' {
    $records=@(& $module { Invoke-AmithTimed 'timing probe' { 'first'; @{Value=2} } } 6>&1)
    $values=@($records|Where-Object {$_ -isnot [Management.Automation.InformationRecord]})
    $messages=@($records|Where-Object {$_ -is [Management.Automation.InformationRecord]}|ForEach-Object ToString)
    Assert-Equal 2 $values.Count
    Assert-Equal 'first' $values[0]
    Assert-Equal 2 $values[1].Value
    Assert-Equal 2 $messages.Count
    Assert-True ($messages[0] -match '\[timing\].*START timing probe')
    Assert-True ($messages[1] -match '\[timing\].*DONE timing probe \([0-9.,]+s\)')
}
Check 'failed timing logs retain the original failure without logging its contents' {
    $records=@(& $module {
        try { Invoke-AmithTimed 'failure probe' { throw [InvalidOperationException]::new('private failure detail') } }
        catch { $_.Exception.GetType().FullName }
    } 6>&1)
    $values=@($records|Where-Object {$_ -isnot [Management.Automation.InformationRecord]})
    $messages=@($records|Where-Object {$_ -is [Management.Automation.InformationRecord]}|ForEach-Object ToString)
    Assert-Equal @('System.InvalidOperationException') $values
    Assert-True ($messages[-1] -match 'FAILED failure probe')
    Assert-True (-not (($messages -join ' ') -match 'private failure detail'))
}
Check 'native nonzero exit stops immediately' { Assert-Throws { & $module { Invoke-AmithNative pwsh @('-NoProfile','-Command','exit 17') } } '*exit code 17*' }
Check 'native output redacts explicitly supplied secrets' {
    $output = @(& $module { Invoke-AmithNative pwsh @('-NoProfile','-Command',"Write-Output 'not-a-real-secret'") -Capture -SensitiveValues @('not-a-real-secret') })
    Assert-Equal @('***') $output
}
Check 'glob matching handles root files, nested paths and project names' {
    Assert-True (& $module { Test-AmithPattern 'Root.csproj' '**/*.csproj' })
    Assert-True (& $module { Test-AmithPattern 'src/Api/Api.csproj' 'src/**/*.csproj' })
    Assert-True (& $module { Test-AmithPattern 'tests/Api.Tests/Api.Tests.csproj' '*.Tests' })
    Assert-True (-not (& $module { Test-AmithPattern 'src/Api/Api.csproj' 'tests/**' }))
}
Check 'metadata uses the selected SDK entry point and fails clearly if it is missing' {
    $root=Join-Path $testRoot 'metadata-sdk'
    $directory=Join-Path $root 'sdk/11.0.100'
    [void][IO.Directory]::CreateDirectory($directory)
    $entry=Join-Path $directory 'MSBuild.dll'
    Set-Content $entry 'fixture'
    $execution=@{Root=$root;Version='11.0.100';Dotnet=(Join-Path $root 'dotnet')}
    $result=& $module {
        param($execution,$entry)
        $original=(Get-Item Function:Invoke-AmithNative).ScriptBlock
        try{
            $script:MetadataProbe=$null
            function script:Invoke-AmithNative {
                param($File,$Arguments,$WorkingDirectory,[switch]$Capture)
                $script:MetadataProbe=@{File=$File;Entry=$Arguments[0];Directory=$WorkingDirectory}
                return '{"Properties":{"TargetFramework":"net10.0"},"Items":{"PackageReference":[]}}'
            }
            $metadata=Get-AmithProjectMetadata 'Fixture.csproj' Release '1.0.0' $execution
            @{Probe=$script:MetadataProbe;Metadata=$metadata}
        }finally{Set-Item Function:script:Invoke-AmithNative $original}
    } $execution $entry
    Assert-Equal $execution.Dotnet $result.Probe.File
    Assert-Equal $entry $result.Probe.Entry
    Assert-Equal 'net10.0' $result.Metadata.TargetFramework
    $missing=@{Root=$root;Version='10.0.404';Dotnet=$execution.Dotnet}
    Assert-Throws {& $module {param($execution)Get-AmithProjectMetadata 'Fixture.csproj' Release '1.0.0' $execution} $missing} '*missing*MSBuild entry point*'
}
Check 'invalid and shell-like versions are rejected' {
    foreach ($value in @('v1.2.3','1.2','1.2.3+metadata','1.2.3;echo bad')) { Assert-Throws { & $module {param($v) Assert-AmithVersion $v} $value } '*Version must*' }
    & $module { Assert-AmithVersion '1.2.3-rc.1' }
}
$fixture = Join-Path $testRoot 'fixture'; [void][IO.Directory]::CreateDirectory($fixture)
foreach ($relative in @('src/Lib/Lib.csproj','src/Api/Api.csproj','src/Desktop/Desktop.csproj','tests/Api.Tests/Api.Tests.csproj','samples/Sample/Sample.csproj')) {
    $path=Join-Path $fixture $relative; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path)); Set-Content -LiteralPath $path -Value '<Project />'
}
Set-Content -LiteralPath (Join-Path $fixture 'Fixture.sln') -Value 'stub solution'
Set-Content -LiteralPath (Join-Path $fixture 'global.json') -Value '{"test":{"runner":"Microsoft.Testing.Platform"}}'
$configPath=Join-Path $fixture 'amith.build.psd1'
Set-Content -LiteralPath $configPath -Value '@{ Solution = ''Fixture.sln''; Runtimes = @(''win-x64'',''linux-x64''); Exclude = @(''samples/**''); Defaults = @{ ArchiveFormats = @(''zip'') }; Overrides = @(@{Match=''src/Lib/*'';Pack=$true}) }'
$originalGhToken=$env:GH_TOKEN; $env:GH_TOKEN='not-a-real-test-token'
$state = @{DownloadMode='Empty';SeedPackId='Amith.Client';FailVpkChannel='';PartialVpk=$false;ReflectReleases=$false;FailToolInstall=$false;Remote=@{tag_name='v1.2.3';draft=$true;assets=@()};AssetId=0;Root=$fixture;Calls=[Collections.Generic.List[object]]::new();FailTest=$false;FailBuild=$false;FailPush=$false;FailUpload=$false}
$sdkRequests=[Collections.Generic.List[object]]::new()
$originalSdkFunctions=@{}
foreach($name in @('Open-AmithSdkScope','Close-AmithSdkScope','Complete-AmithSdkScope')){
    $originalSdkFunctions[$name]=& $module {param($name)(Get-Item "Function:$name").ScriptBlock} $name
}
& $module {
    param($requests)
    $script:SdkRequests=$requests
    function script:Open-AmithSdkScope {param($RootPath,$SdkVersion,$AdditionalSdks,$Execution) $script:SdkRequests.Add(@{Root=$RootPath;Selector=$SdkVersion;Additional=$AdditionalSdks}); return @{Execution=$null}}
    function script:Close-AmithSdkScope {param($Scope)}
    function script:Complete-AmithSdkScope {param($Scope,$TargetFrameworks,$ProjectDirectories) return $null}
} $sdkRequests
$originalNative = & $module { (Get-Item Function:Invoke-AmithNative).ScriptBlock }
& $module {
    param($State)
    $script:TestState = $State
    function script:New-AmithTestPackage($Path,$Id,$Version) {
        $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
        try {$entry=$zip.CreateEntry('package.nuspec');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write("<package><metadata><id>$Id</id><version>$Version</version></metadata></package>")}finally{$writer.Dispose()}}finally{$zip.Dispose()}
    }
    function script:Add-AmithTestRemoteAsset($Name,$Path) {
        $script:TestState.AssetId++
        $script:TestState.Remote.assets=@($script:TestState.Remote.assets|Where-Object name -cne $Name)+@(@{name=$Name;id=$script:TestState.AssetId;size=(Get-Item -LiteralPath $Path).Length;digest=('sha256:'+(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())})
    }
    Set-Item Function:script:Invoke-AmithNative -Value {
        param([string]$File,[string[]]$Arguments=@(),[string]$WorkingDirectory,[switch]$Capture,[string[]]$SensitiveValues=@())
        $script:TestState.Calls.Add(@{File=$File;Arguments=@($Arguments);SensitiveValues=@($SensitiveValues)})
        if ($File -eq 'git') { if ($Arguments[0] -eq 'rev-parse') { return '0123456789012345678901234567890123456789' }; return }
        if ($File -eq 'gh') {
            if ($Arguments[0] -eq 'api') {
                if ($Arguments[1] -like '*/releases/tags/*') { throw 'GitHub draft by-tag lookup returned HTTP 404' }
                if ($Arguments[1] -notlike '*/releases/42') { throw 'Unexpected release API URL' }
                return ($script:TestState.Remote|ConvertTo-Json -Depth 20)
            }
            if ($Arguments[1] -eq 'view') {
                $repository=$Arguments[([array]::IndexOf($Arguments,'--repo')+1)]
                return (@{apiUrl="https://api.github.com/repos/$repository/releases/42"}|ConvertTo-Json)
            }
            if ($Arguments[1] -eq 'list') {
                if($script:TestState.ReflectReleases){return (@(@{tagName=$script:TestState.Remote.tag_name;isDraft=$script:TestState.Remote.draft})|ConvertTo-Json -AsArray)}
                return '[]'
            }
            if ($Arguments[1] -eq 'create') {$script:TestState.Remote=@{tag_name=$Arguments[2];draft=$true;assets=@()}}
            if ($Arguments[1] -eq 'edit') {$script:TestState.Remote.draft=$false}
            if ($Arguments[1] -eq 'upload' -and $script:TestState.FailUpload) { throw 'simulated upload failure' }; return
        }
        if ([IO.Path]::GetFileNameWithoutExtension($File) -eq 'vpk') {
            if ($Arguments -contains '--help') { return 'Velopack CLI 1.2.161' }
            $dir=$Arguments[([array]::IndexOf($Arguments,'--outputDir')+1)];[void][IO.Directory]::CreateDirectory($dir)
            $channel=$Arguments[([array]::IndexOf($Arguments,'--channel')+1)]
            if($Arguments -contains 'download') {
                switch($script:TestState.DownloadMode) {
                    Error {throw 'simulated authentication/network download failure'}
                    Incomplete {Set-Content -LiteralPath (Join-Path $dir 'failed.nupkg.incomplete') -Value 'corrupt';return}
                    Corrupt {Set-Content -LiteralPath (Join-Path $dir 'corrupt.nupkg') -Value 'not a zip';return}
                    Seed {New-AmithTestPackage (Join-Path $dir 'previous-full.nupkg') $script:TestState.SeedPackId '0.9.0';return}
                    default {return}
                }
            }
            if($Arguments -contains 'upload') {
                $entries=@(Get-Content -Raw -LiteralPath (Join-Path $dir "assets.$channel.json")|ConvertFrom-Json -AsHashtable)
                if($channel -eq $script:TestState.FailVpkChannel) {
                    if($script:TestState.PartialVpk) {Add-AmithTestRemoteAsset $entries[0].RelativeFileName (Join-Path $dir $entries[0].RelativeFileName)}
                    throw 'simulated Velopack upload failure'
                }
                foreach($entry in $entries) {Add-AmithTestRemoteAsset $entry.RelativeFileName (Join-Path $dir $entry.RelativeFileName)}
                Add-AmithTestRemoteAsset "releases.$channel.json" (Join-Path $dir "releases.$channel.json")
                if($channel -ceq 'win'){Add-AmithTestRemoteAsset 'RELEASES' (Join-Path $dir 'RELEASES')}
                return
            }
            $packId=$Arguments[([array]::IndexOf($Arguments,'--packId')+1)];$version=$Arguments[([array]::IndexOf($Arguments,'--packVersion')+1)]
            $setup="$packId-$channel-Setup.exe";$package="$packId-$version-$channel-full.nupkg"
            Set-Content -LiteralPath (Join-Path $dir $setup) -Value 'installer contents'
            New-AmithTestPackage (Join-Path $dir $package) $packId $version
            Set-Content -LiteralPath (Join-Path $dir "assets.$channel.json") -Value (ConvertTo-Json -InputObject @(@{RelativeFileName=$setup;Type=2},@{RelativeFileName=$package;Type=0}))
            Set-Content -LiteralPath (Join-Path $dir "releases.$channel.json") -Value '{"Assets":[]}'
            if($channel -ceq 'win'){Set-Content -LiteralPath (Join-Path $dir 'RELEASES') -Value 'legacy feed'}
            return
        }
        if ($File -ne 'dotnet') { throw "Unexpected mocked tool: $File" }
        switch ($Arguments[0]) {
            sln { return @('Project(s)','----------','src/Lib/Lib.csproj','src/Api/Api.csproj','src/Desktop/Desktop.csproj','tests/Api.Tests/Api.Tests.csproj','samples/Sample/Sample.csproj') }
            msbuild {
                $name=[IO.Path]::GetFileNameWithoutExtension($Arguments[1])
                $properties=@{OutputType='Library';IsTestProject='false';IsPackable='true';TargetFramework='net10.0';TargetFrameworks='';RuntimeIdentifier='';RuntimeIdentifiers='';UseWPF='false';UseWindowsForms='false';UsingMicrosoftNETSdkWeb='false';PackageId=$name;AssemblyName=$name}
                if($name -eq 'Worker'){$properties.OutputType='Exe'}
                if($name -eq 'Api'){$properties.OutputType='Exe';$properties.UsingMicrosoftNETSdkWeb='true'}
                if($name -eq 'Desktop'){$properties.OutputType='WinExe';$properties.UseWPF='true';$properties.TargetFramework='net10.0-windows'}
                if($name -eq 'Api.Tests'){$properties.IsTestProject='true';$properties.IsPackable='false'}
                if($name -eq 'Controls'){$properties.UseWPF='true'}
                if($name -eq 'NotPackable'){$properties.IsPackable='false'}
                if($name -eq 'Cold.Tests'){$properties.OutputType='Exe';$properties.IsTestProject='';return (@{Properties=$properties;Items=@{PackageReference=@(@{Identity='Microsoft.NET.Test.Sdk'})}}|ConvertTo-Json -Depth 8)}
                return (@{Properties=$properties}|ConvertTo-Json -Depth 5)
            }
            '--version' { return '10.0.401' }
            tool { $dir=$Arguments[([array]::IndexOf($Arguments,'--tool-path')+1)];[void][IO.Directory]::CreateDirectory($dir);Set-Content -LiteralPath (Join-Path $dir $(if($IsWindows){'vpk.exe'}else{'vpk'})) -Value 'fake tool';if($script:TestState.FailToolInstall){throw 'simulated tool install failure'};return }
            build { if($script:TestState.FailBuild){throw 'simulated build failure'};return }
            restore { return }; test { if($script:TestState.FailTest){throw 'simulated test failure'};return }
            nuget { if($script:TestState.FailPush){throw 'simulated feed failure'};return }
            pack {
                $dir=$Arguments[([array]::IndexOf($Arguments,'--output')+1)]
                $version=($Arguments|Where-Object{$_ -like '-p:Version=*'}) -replace '^-p:Version=',''
                $name=[IO.Path]::GetFileNameWithoutExtension($Arguments[1])
                Set-Content -LiteralPath (Join-Path $dir "$name.$version.nupkg") -Value 'package contents';return
            }
            publish {
                $dir=$Arguments[([array]::IndexOf($Arguments,'--output')+1)];[void][IO.Directory]::CreateDirectory($dir)
                Set-Content -LiteralPath (Join-Path $dir 'app.dll') -Value 'application contents'
                Set-Content -LiteralPath (Join-Path $dir '.hidden-config') -Value 'hidden content';return
            }
            default { throw "Unexpected mocked dotnet command: $($Arguments[0])" }
        }
    }
} $state
function New-FixturePlan([string]$Version='1.2.3') { New-AmithBuildPlan -ConfigPath $configPath -Version $Version -PlanPath (Join-Path $testRoot ([Guid]::NewGuid().ToString('N')+'.json')) }
try {
    Check 'automatic discovery classifies libraries, web, desktop and tests' {
        $p=New-FixturePlan
        Assert-Equal @('Api','Desktop','Lib','Api.Tests') @($p.Projects|ForEach-Object Name)
        Assert-Equal 'Web' (@($p.Projects|Where-Object Name -eq Api)[0].Kind)
        Assert-Equal 'Library' (@($p.Projects|Where-Object Name -eq Lib)[0].Kind)
        Assert-Equal 'Test' (@($p.Projects|Where-Object Name -eq Api.Tests)[0].Kind)
    }
    Check 'container definitions and latest policy are resolved and saved by Plan' {
        Set-Content -LiteralPath (Join-Path $fixture 'Dockerfile') -Value 'FROM scratch'
        $config=Join-Path $fixture 'containers.psd1'
        Set-Content -LiteralPath $config -Value '@{Solution=''Fixture.sln'';Containers=@(@{Name=''api'';Image=''harbor.example.com/project/api''});Release=@{Containers=@{Enabled=$true;TagAsLatest=$true}}}'
        $p=New-AmithBuildPlan -ConfigPath $config -Version 1.2.3 -PlanPath (Join-Path $testRoot 'container-plan.json')
        $saved=Read-Plan $p.PlanPath
        Assert-Equal 1 $saved.Containers.Count;Assert-Equal '1.2.3' $saved.Containers[0].Tag
        Assert-Equal (Join-Path $fixture 'Dockerfile') $saved.Containers[0].Dockerfile
        Assert-True $saved.Release.Containers.TagAsLatest
        Set-Content -LiteralPath $config -Value '@{Solution=''Fixture.sln'';Release=@{Containers=@{Enabled=$true}}}'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $config -Version 1.2.3 -PlanPath (Join-Path $testRoot 'invalid-container-plan.json')} '*no container images*'
    }
    Check 'one runtime list produces both API targets and supported desktop targets' {
        $p=New-FixturePlan
        Assert-Equal @('win-x64','linux-x64') @(@($p.Projects|Where-Object Name -eq Api)[0].Targets|ForEach-Object Runtime)
        Assert-Equal @('win-x64') @(@($p.Projects|Where-Object Name -eq Desktop)[0].Targets|ForEach-Object Runtime)
        Assert-Equal 0 @(@($p.Projects|Where-Object Name -eq Lib)[0].Targets).Count
    }
    Check 'explicit mode uses supplied roots and per-project exceptions' {
        $explicit=Join-Path $fixture 'explicit.psd1'
        Set-Content -LiteralPath $explicit -Value '@{Discover=$false;Projects=@(@{Path=''src/Api/Api.csproj'';Runtimes=@(''linux-x64'')})}'
        $p=New-AmithBuildPlan -ConfigPath $explicit -PlanPath (Join-Path $testRoot 'explicit.json')
        Assert-Equal 1 $p.Projects.Count;Assert-Equal @('linux-x64') @($p.Projects[0].Targets|ForEach-Object Runtime);Assert-True (-not $p.ExplicitVersion)
    }
    Check 'single-project shorthand selects only that root and both runtimes' {
        $p=New-AmithBuildPlan -ConfigPath $configPath -Project 'src/Api/Api.csproj' -Version 1.2.3 -PlanPath (Join-Path $testRoot 'single-project.json')
        Assert-Equal 1 $p.Projects.Count
        Assert-Equal Api $p.Projects[0].Name
        Assert-Equal @('win-x64','linux-x64') @($p.Projects[0].Targets|ForEach-Object Runtime)
    }
    Check 'discovery and explicit overrides merge without duplication' {
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Api/Api.csproj';SelfContained=$true}) -PlanPath (Join-Path $testRoot 'merged.json')
        Assert-True @($p.Projects|Where-Object Name -eq Api)[0].SelfContained;Assert-Equal 4 $p.Projects.Count
    }
    Check 'WPF control libraries are packable libraries rather than desktop executables' {
        $file=Join-Path $fixture 'src/Controls/Controls.csproj';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $file));Set-Content -LiteralPath $file -Value '<Project />'
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Controls/Controls.csproj'}) -PlanPath (Join-Path $testRoot 'controls.json')
        Assert-Equal Library @($p.Projects|Where-Object Name -eq Controls)[0].Kind
    }
    Check 'test SDK references identify tests before package-generated props exist' {
        $file=Join-Path $fixture 'tests/Cold.Tests/Cold.Tests.csproj';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $file));Set-Content -LiteralPath $file -Value '<Project />'
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='tests/Cold.Tests/Cold.Tests.csproj'}) -PlanPath (Join-Path $testRoot 'cold.json')
        Assert-Equal Test @($p.Projects|Where-Object Name -eq Cold.Tests)[0].Kind
    }
    Check 'application kinds default to self-contained single-file while libraries and tests do not' {
        $path=Join-Path $fixture 'src/Worker/Worker.csproj'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));Set-Content -LiteralPath $path -Value '<Project />'
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Worker/Worker.csproj'}) -PlanPath (Join-Path $testRoot 'deployment-defaults.json')
        Assert-Equal Console @($p.Projects|Where-Object Name -eq Worker)[0].Kind
        foreach($project in $p.Projects) {
            $app=$project.Kind -in @('Desktop','Web','Console')
            Assert-Equal $app $project.SelfContained;Assert-Equal $app $project.SingleFile
        }
        Assert-True (-not @($p.Projects|Where-Object Name -eq Api)[0].SelfExtract)
    }
    Check 'configuration can disable application deployment defaults' {
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Api/Api.csproj';SelfContained=$false;SingleFile=$false}) -PlanPath (Join-Path $testRoot 'deployment-config.json')
        $api=@($p.Projects|Where-Object Name -eq Api)[0]
        Assert-True (-not $api.SelfContained);Assert-True (-not $api.SingleFile)
    }
    Check 'standalone shortcut overrides configuration for apps only and persists publish arguments' {
        $p=Invoke-AmithBuild -ConfigPath $configPath -Projects @(@{Path='src/Api/Api.csproj';SelfContained=$false;SingleFile=$false}) -StandaloneSingleFile -Version 1.2.3 -PlanOnly -PlanPath (Join-Path $testRoot 'deployment-shortcut.json')
        foreach($project in $p.Projects) {
            $app=$project.Kind -in @('Desktop','Web','Console')
            Assert-Equal $app $project.SelfContained;Assert-Equal $app $project.SingleFile
        }
        $state.Calls.Clear();$p=Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Restore,Build,Publish
        foreach($call in @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'publish'})) {
            Assert-Equal true $call.Arguments[([array]::IndexOf($call.Arguments,'--self-contained')+1)]
            Assert-True ($call.Arguments -contains '-p:PublishSingleFile=true')
        }
    }
    Check 'explicit false switches override defaults and survive public API forwarding' {
        $p=Invoke-AmithBuild -ConfigPath $configPath -SelfContained:$false -SingleFile:$false -Version 1.2.3 -PlanOnly -PlanPath (Join-Path $testRoot 'deployment-false.json')
        foreach($project in $p.Projects) {Assert-True (-not $project.SelfContained);Assert-True (-not $project.SingleFile)}
        $state.Calls.Clear();$p=Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Restore,Build,Publish
        foreach($call in @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'publish'})) {
            Assert-Equal false $call.Arguments[([array]::IndexOf($call.Arguments,'--self-contained')+1)]
            Assert-True ($call.Arguments -contains '-p:PublishSingleFile=false')
        }
        $p=Invoke-AmithBuild -ConfigPath $configPath -SelfContained:$false -PlanOnly -PlanPath (Join-Path $testRoot 'deployment-mixed.json')
        $api=@($p.Projects|Where-Object Name -eq Api)[0]
        Assert-True (-not $api.SelfContained);Assert-True $api.SingleFile
    }
    Check 'shortcut conflicts and its explicit false value are rejected' {
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -StandaloneSingleFile -SelfContained} '*cannot be combined*'
        Assert-Throws {Invoke-AmithBuild -ConfigPath $configPath -StandaloneSingleFile -SingleFile:$false -PlanOnly} '*cannot be combined*'
        Assert-Throws {Invoke-AmithBuild -ConfigPath $configPath -StandaloneSingleFile:$false -PlanOnly} '*enable-only*'
    }
    Check 'archive names default to unversioned and support defaults with per-project exceptions' {
        $p=New-FixturePlan
        foreach($project in $p.Projects) { Assert-True (-not $project.VersionedArchives) }
        $config=Join-Path $fixture 'archive-config.psd1'
        Set-Content -LiteralPath $config -Value '@{Solution=''Fixture.sln'';Exclude=@(''samples/**'');Defaults=@{VersionedArchives=$true};Overrides=@(@{Match=''Desktop'';VersionedArchives=$false})}'
        $p=New-AmithBuildPlan -ConfigPath $config -PlanPath (Join-Path $testRoot 'archive-config.json')
        Assert-True @($p.Projects|Where-Object Name -eq Api)[0].VersionedArchives
        Assert-True (-not @($p.Projects|Where-Object Name -eq Desktop)[0].VersionedArchives)
    }
    Check 'canonical archive switches and convenience switch override configuration and persist' {
        $config=Join-Path $fixture 'archive-config.psd1'
        foreach($options in @(@{VersionedArchives=$true},@{VersionedArchives=$false},@{UnversionedArchives=$true})) {
            $p=Invoke-AmithBuild -ConfigPath $config @options -PlanOnly -PlanPath (Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.json'))
            $expected=$options.ContainsKey('VersionedArchives') -and $options.VersionedArchives
            foreach($project in (Read-Plan $p.PlanPath).Projects) { Assert-Equal ([bool]$expected) $project.VersionedArchives }
        }
    }
    Check 'archive naming switch conflicts and false convenience values are rejected' {
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -VersionedArchives -UnversionedArchives} '*cannot be combined*'
        Assert-Throws {Invoke-AmithBuild -ConfigPath $configPath -VersionedArchives:$false -UnversionedArchives -PlanOnly} '*cannot be combined*'
        Assert-Throws {Invoke-AmithBuild -ConfigPath $configPath -UnversionedArchives:$false -PlanOnly} '*enable-only*'
    }
    Check 'saved plans control actual archive names without changing NuGet filenames' {
        foreach($versioned in @($false,$true)) {
            $p=Invoke-AmithBuild -ConfigPath $configPath -Version 1.2.3 -VersionedArchives:$versioned -PlanOnly -PlanPath (Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.json'))
            $p=Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Restore,Build,Pack,Publish,Archive
            $suffix=if($versioned){'-1.2.3'}else{''}
            Assert-Equal @("Api-win-x64$suffix.zip","Api-linux-x64$suffix.zip","Desktop-win-x64$suffix.zip") @($p.Artifacts|Where-Object Kind -eq Archive|ForEach-Object{Split-Path -Leaf $_.Path})
            Assert-Equal 'Lib.1.2.3.nupkg' (Split-Path -Leaf @($p.Artifacts|Where-Object Kind -eq NuGet)[0].Path)
        }
    }
    Check 'different releases can retain identical unversioned archive filenames' {
        $results=@()
        foreach($version in @('1.2.3','2.0.0')) {
            $p=Invoke-AmithBuild -ConfigPath $configPath -Version $version -UnversionedArchives -Stages Restore,Build,Publish,Archive -PlanPath (Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.json'))
            $results+=@($p.Artifacts|Where-Object Kind -eq Archive)[0].Path
        }
        Assert-Equal (Split-Path -Leaf $results[0]) (Split-Path -Leaf $results[1])
        Assert-True ($results[0] -ne $results[1]);foreach($path in $results) {Assert-True (Test-Path -LiteralPath $path)}
    }
    Check 'libraries default to no packaging independently of SDK packability' {
        $p=New-AmithBuildPlan -RootPath $fixture -Project src/Controls/Controls.csproj -PlanPath (Join-Path $testRoot 'default-pack.json')
        Assert-Equal Library $p.Projects[0].Kind; Assert-True $p.Projects[0].IsPackable
        Assert-True (-not $p.Projects[0].Pack)
    }
    Check 'repository packaging default applies only to libraries' {
        $config=Join-Path $fixture 'all-pack.psd1'
        Set-Content -LiteralPath $config -Value '@{Solution=''Fixture.sln'';Exclude=@(''samples/**'');Defaults=@{Pack=$true}}'
        $p=New-AmithBuildPlan -ConfigPath $config -PlanPath (Join-Path $testRoot 'all-pack.json')
        Assert-Equal @('Lib') @($p.Projects|Where-Object Pack|ForEach-Object Name)
    }
    Check 'additive selection retains configured packages and persists for later stages' {
        $p=Invoke-AmithBuild -ConfigPath $configPath -Projects @(@{Path='src/Controls/Controls.csproj'}) -PackProjects Controls -Version 1.2.3 -PlanOnly -PlanPath (Join-Path $testRoot 'add-pack.json')
        Assert-Equal @('Controls','Lib') @($p.Projects|Where-Object Pack|ForEach-Object Name)
        $state.Calls.Clear()
        $p=Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Restore,Build,Pack
        Assert-Equal @('Controls','Lib') @($p.Artifacts|Where-Object Kind -eq NuGet|ForEach-Object Project)
    }
    Check 'only selection replaces configuration and exclusion wins over inclusion' {
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Controls/Controls.csproj'}) -PackOnlyProjects Controls -PlanPath (Join-Path $testRoot 'only-pack.json')
        Assert-Equal @('Controls') @($p.Projects|Where-Object Pack|ForEach-Object Name)
        $p=New-AmithBuildPlan -ConfigPath $configPath -PackProjects Lib -ExcludePackProjects Lib -PlanPath (Join-Path $testRoot 'exclude-pack.json')
        Assert-Equal 0 @($p.Projects|Where-Object Pack).Count
    }
    Check 'all libraries skips nonpackable libraries and respects exclusions' {
        $path=Join-Path $fixture 'src/NotPackable/NotPackable.csproj'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));Set-Content -LiteralPath $path -Value '<Project />'
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Controls/Controls.csproj'},@{Path='src/NotPackable/NotPackable.csproj'}) -PackAllLibraries -ExcludePackProjects Lib -PlanPath (Join-Path $testRoot 'bulk-pack.json')
        Assert-Equal @('Controls') @($p.Projects|Where-Object Pack|ForEach-Object Name)
    }
    Check 'explicit requests and configured packaging respect IsPackable=false' {
        $selectionArguments=@{ConfigPath=$configPath;Projects=@(@{Path='src/NotPackable/NotPackable.csproj'});PlanPath=(Join-Path $testRoot 'invalid-pack.json')}
        Assert-Throws {New-AmithBuildPlan @selectionArguments -PackProjects NotPackable} '*IsPackable=false*'
        $selectionArguments.Projects=@(@{Path='src/NotPackable/NotPackable.csproj';Pack=$true})
        Assert-Throws {New-AmithBuildPlan @selectionArguments} '*IsPackable=false*'
        $p=New-AmithBuildPlan @selectionArguments -NoPack
        Assert-Equal 0 @($p.Projects|Where-Object Pack).Count
    }
    Check 'unknown projects patterns and nonlibrary selections produce clear errors' {
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -PackProjects Typo} '*Unknown packaging project*'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -ExcludePackProjects 'L*'} '*Unknown packaging project*'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -PackOnlyProjects Api} '*not a library*'
    }
    Check 'empty explicit selections are rejected and project names are case insensitive' {
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -PackOnlyProjects @()}
        Assert-Throws {Invoke-AmithBuild -ConfigPath $configPath -PackProjects '' -PlanOnly}
        $p=New-AmithBuildPlan -ConfigPath $configPath -PackOnlyProjects lib -PlanPath (Join-Path $testRoot 'case-pack.json')
        Assert-Equal @('Lib') @($p.Projects|Where-Object Pack|ForEach-Object Name)
    }
    Check 'ambiguous packaging switches are rejected' {
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -NoPack -PackAllLibraries} '*NoPack cannot*'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -NoPack -PackProjects Lib} '*NoPack cannot*'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -NoPack -ExcludePackProjects Lib} '*NoPack cannot*'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -PackOnlyProjects Lib -PackProjects Lib} '*PackOnlyProjects cannot*'
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -PackOnlyProjects Lib -PackAllLibraries} '*PackOnlyProjects cannot*'
    }
    Check 'no pack suppresses packages while leaving application publishing enabled' {
        $p=Invoke-AmithBuild -ConfigPath $configPath -Version 1.2.3 -NoPack -Stages Restore,Build,Pack,Publish -PlanPath (Join-Path $testRoot 'no-pack.json')
        Assert-Equal 0 @($p.Artifacts|Where-Object Kind -eq NuGet).Count
        Assert-Equal 3 @($p.Artifacts|Where-Object Kind -eq PublishDirectory).Count
    }
    Check 'selection options create a fresh plan rather than silently reusing existing choices' {
        $p=New-FixturePlan
        $p=Invoke-AmithBuild -ConfigPath $configPath -PlanPath $p.PlanPath -NoPack -PlanOnly
        Assert-Equal 0 @($p.Projects|Where-Object Pack).Count
        Assert-Equal 0 $p.Stages.Count
    }
    Check 'schema identifier is the exact string 1alpha1 in generated and persisted plans' {
        $p=New-FixturePlan
        Assert-True ($p.SchemaVersion -is [string]);Assert-Equal '1alpha1' $p.SchemaVersion
        $saved=Read-Plan $p.PlanPath
        Assert-True ($saved.SchemaVersion -is [string]);Assert-Equal '1alpha1' $saved.SchemaVersion
        $loaded=& $module {param($file)Read-AmithPlan $file} $p.PlanPath
        Assert-Equal '1alpha1' $loaded.SchemaVersion
    }
    Check 'schema validation rejects numeric missing and unsupported identifiers' {
        $p=New-FixturePlan
        foreach($value in @(1,2,'2','v1alpha1','1Alpha1','1alpha2','1beta1','1',$null)) {
            $p.SchemaVersion=$value
            & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
            Assert-Throws {Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Pack} '*expected*1alpha1*Regenerate the plan*'
        }
        [void]$p.Remove('SchemaVersion')
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        Assert-Throws {Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Pack} '*expected*1alpha1*Regenerate the plan*'
    }
    Check 'legacy kinds and saved plans require explicit migration' {
        Assert-Throws {New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='src/Lib/Lib.csproj';Kind='NuGet'})} '*use Kind*Library*'
        $p=New-FixturePlan; $p.SchemaVersion=1
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        Assert-Throws {Invoke-AmithBuild -PlanPath $p.PlanPath -Stages Pack} '*regenerate the plan*'
    }
    Check 'platform exceptions explicitly skip test targets and record the decision' {
        $other=if($IsWindows){'Linux'}else{'Windows'}
        $p=New-AmithBuildPlan -ConfigPath $configPath -Projects @(@{Path='tests/Api.Tests/Api.Tests.csproj';TestPlatforms=@($other)}) -PlanPath (Join-Path $testRoot 'test-platform.json')
        Assert-Equal 0 @(@($p.Projects|Where-Object Name -eq Api.Tests)[0].TestFrameworks).Count
    }
    Check 'each plan has an isolated output path' { $a=New-FixturePlan;$b=New-FixturePlan;Assert-True ($a.OutputRoot -ne $b.OutputRoot) }
    Check 'stage gates reject packing before a successful build' {
        $p=New-FixturePlan;Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Pack} '*successful Build*';Assert-Equal Failed (Read-Plan $p.PlanPath).Stages.Pack.Status
    }
    Check 'failed builds block packaging and persist failed state' {
        $p=New-FixturePlan;Invoke-AmithBuildStage $p.PlanPath Restore|Out-Null;$state.FailBuild=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Build} '*simulated build failure*'} finally {$state.FailBuild=$false}
        Assert-Equal Failed (Read-Plan $p.PlanPath).Stages.Build.Status;Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Pack} '*successful Build*'
    }
    Check 'individual stages reuse the saved plan and emit current-run artifacts' {
        $script:built=New-FixturePlan
        foreach($stage in @('Restore','Build','Test','Pack','Publish','Archive','Installer')){$script:built=Invoke-AmithBuild -PlanPath $script:built.PlanPath -Stages $stage}
        Assert-Equal @('NuGet','PublishDirectory','PublishDirectory','PublishDirectory','Archive','Archive','Archive') @($script:built.Artifacts|ForEach-Object Kind)
        Assert-Equal 1 $script:built.TestResults.ExecutedTargets
        Assert-True (@($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'test' -and $_.Arguments[1] -eq '--project'}).Count -gt 0)
    }
    Check 'restore build and tests use matching framework runtime and version properties' {
        $state.Calls.Clear(); $p=New-FixturePlan
        foreach($stage in @('Restore','Build','Test')) { $p=Invoke-AmithBuildStage $p.PlanPath $stage }
        $calls=@($state.Calls|Where-Object { $_.File -eq 'dotnet' -and $_.Arguments[0] -in @('restore','build','test') -and ($_.Arguments -join ' ') -like '*Api.Tests.csproj*' })
        Assert-Equal 4 $calls.Count
        foreach($call in $calls) {
            Assert-True ($call.Arguments -contains '-p:TargetFramework=net10.0')
            Assert-True ($call.Arguments -contains '-p:Version=1.2.3')
            Assert-Equal ([Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier) $call.Arguments[([array]::IndexOf($call.Arguments,'--runtime')+1)]
        }
        Assert-True (-not ($calls[1].Arguments -contains '--no-restore'))
    }
    Check 'per-project publishing and archiving exceptions are respected' {
        $p=New-AmithBuildPlan -ConfigPath $configPath -Version 1.2.3 -Projects @(@{Path='src/Desktop/Desktop.csproj';Publish=$false},@{Path='src/Api/Api.csproj';Archive=$false}) -PlanPath (Join-Path $testRoot 'publish-exceptions.json')
        foreach($stage in @('Restore','Build','Test','Pack','Publish','Archive')){$p=Invoke-AmithBuildStage $p.PlanPath $stage}
        Assert-Equal 2 @($p.Artifacts|Where-Object Kind -eq PublishDirectory).Count
        Assert-Equal 0 @($p.Artifacts|Where-Object Kind -eq Archive).Count
    }
    Check 'archives include hidden files without surrounding variables' {
        $zip=@($script:built.Artifacts|Where-Object Kind -eq Archive)[0].Path;$archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try {Assert-True (@($archive.Entries|Where-Object FullName -eq '.hidden-config').Count -eq 1)} finally {$archive.Dispose()}
    }
    Check 'installer adapter uses target OS and RID rather than runner OS' {
        $p=Read-Plan $script:built.PlanPath
        @($p.Projects|Where-Object Name -eq Desktop)[0].Velopack=@{Enabled=$true;PackId='Amith.Client';MainExe='Client.exe';ToolVersion='1.2.161';DownloadPrevious=$false}
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $state.Calls.Clear();$p=Invoke-AmithBuildStage $p.PlanPath Installer
        $call=@($state.Calls|Where-Object{[IO.Path]::GetFileNameWithoutExtension($_.File) -eq 'vpk' -and $_.Arguments -contains 'pack'})[0]
        Assert-Equal '[win]' $call.Arguments[0]
        Assert-Equal 'win-x64' $call.Arguments[([array]::IndexOf($call.Arguments,'--runtime')+1)]
        Assert-Equal 3 @($p.Artifacts|Where-Object Kind -eq Installer).Count
    }
    Check 'release can require an actually executed test target' {
        $p=New-FixturePlan;$p.Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'}}
        $p.Release=@{RequireTestExecution=$true};$p.TestResults=@{ExecutedTargets=0}
        Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*at least one executed test*'
    }
    Check 'tampered artifacts cannot be released' {
        $p=New-FixturePlan;$p.Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'};Pack=@{Status='Succeeded'}}
        $dir=Join-Path $p.OutputRoot 'packages';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'changed.nupkg';Set-Content -LiteralPath $file -Value original
        & $module {param($p,$file)Add-AmithArtifact $p NuGet $p.Projects[0] $file} $p $file
        Set-Content -LiteralPath $file -Value tampered;Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*changed since packaging*'
    }
    Check 'partially failed producer stages cannot release their earlier artifacts' {
        $p=Read-Plan $script:built.PlanPath
        $p.Stages.Archive.Status='Failed'
        Assert-Throws {& $module {param($p)Assert-AmithReleaseArtifacts $p} $p} '*successful Archive*'
    }
    Check 'failed remote pushes retain local packages' {
        $p=Read-Plan $script:built.PlanPath;$p.Release=@{NuGet=@{Enabled=$true;SourceEnvironment='AMITH_TEST_FEED';ApiKeyEnvironment='AMITH_TEST_KEY'}}
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $oldFeed=$env:AMITH_TEST_FEED;$oldKey=$env:AMITH_TEST_KEY;$env:AMITH_TEST_FEED='https://example.invalid/nuget';$env:AMITH_TEST_KEY='not-a-real-key';$state.FailPush=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*simulated feed failure*'} finally {$state.FailPush=$false;$env:AMITH_TEST_FEED=$oldFeed;$env:AMITH_TEST_KEY=$oldKey}
        Assert-True (Test-Path -LiteralPath @($p.Artifacts|Where-Object Kind -eq NuGet)[0].Path)
    }
    Check 'retrying a successful package push does not republish it' {
        $p=Read-Plan $script:built.PlanPath
        $p.Release=@{NuGet=@{Enabled=$true;SourceEnvironment='AMITH_TEST_FEED';ApiKeyEnvironment='AMITH_TEST_KEY'}}
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $oldFeed=$env:AMITH_TEST_FEED;$oldKey=$env:AMITH_TEST_KEY;$env:AMITH_TEST_FEED='https://example.invalid/nuget';$env:AMITH_TEST_KEY='not-a-real-key';$state.Calls.Clear()
        try {Invoke-AmithBuildStage $p.PlanPath Release|Out-Null;Invoke-AmithBuildStage $p.PlanPath Release|Out-Null}
        finally {$env:AMITH_TEST_FEED=$oldFeed;$env:AMITH_TEST_KEY=$oldKey}
        Assert-Equal 1 @($state.Calls|Where-Object{$_.File -eq 'dotnet' -and $_.Arguments[0] -eq 'nuget'}).Count
    }
    Check 'GitHub creates a draft and uploads before publication' {
        $p=Read-Plan $script:built.PlanPath;$p.Release=@{GitHub=@{Enabled=$true;Repository='Amith211/Example';RequireCleanTree=$false}};$p.SourceCommit='0123456789012345678901234567890123456789'
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $state.Calls.Clear();Invoke-AmithBuildStage $p.PlanPath Release|Out-Null;$calls=@($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[0] -eq 'release' -and $_.Arguments[1] -ne 'view'})
        Assert-Equal @('list','create','upload','edit') @($calls|ForEach-Object{$_.Arguments[1]});Assert-True ($calls[1].Arguments -contains '--draft')
    }
    Check 'source-commit changes block GitHub release before uploading' {
        $p=Read-Plan $script:built.PlanPath;$p.SourceCommit='different-commit'
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*source commit changed*'
        $p.SourceCommit='0123456789012345678901234567890123456789'
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    }
    Check 'failed GitHub uploads never promote the draft' {
        $p=Read-Plan $script:built.PlanPath;$state.Calls.Clear();$state.FailUpload=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*simulated upload failure*'} finally {$state.FailUpload=$false}
        Assert-Equal 0 @($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[1] -eq 'edit'}).Count
    }
    Check 'retention after release failure preserves verified packages and the failed release state' {
        $p=Read-Plan $script:built.PlanPath
        $p.Release=@{GitHub=@{Enabled=$true;Repository='Amith211/Example';RequireCleanTree=$false}}
        $p.SourceCommit='0123456789012345678901234567890123456789'
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $state.FailUpload=$true
        try{Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*simulated upload failure*'}
        finally{$state.FailUpload=$false}
        $p=Invoke-AmithBuildStage $p.PlanPath Retain
        Assert-Equal Failed $p.Stages.Release.Status
        Assert-Equal Succeeded $p.Stages.Retain.Status
        Assert-True (Test-Path -LiteralPath $p.RetainedRoot -PathType Container)
        $selected=@($p.Artifacts|Where-Object Kind -in Archive,Installer,NuGet,Symbols)
        Assert-True ($selected.Count -gt 0)
        Assert-Equal $selected.Count @(Get-ChildItem -LiteralPath $p.RetainedRoot -Recurse -File).Count
    }
    . (Join-Path $PSScriptRoot 'VelopackChecks.ps1')
    . (Join-Path $PSScriptRoot 'ToolCacheChecks.ps1')
    . (Join-Path $PSScriptRoot 'PackagingChecks.ps1')
    . (Join-Path $PSScriptRoot 'ConfigDiscoveryChecks.ps1')
    . (Join-Path $PSScriptRoot 'TestPolicyChecks.ps1')
    . (Join-Path $PSScriptRoot 'SdkResolutionChecks.ps1')
    . (Join-Path $PSScriptRoot 'SdkExecutionPlanChecks.ps1')
    Check 'rebuilding invalidates previous artifact and release gates' {
        $p=Invoke-AmithBuildStage $script:built.PlanPath Build;Assert-Equal 0 $p.Artifacts.Count;Assert-True (-not $p.Stages.Contains('Pack'))
    }
    Check 'artifact paths cannot escape the output root' {
        $p=New-FixturePlan;Assert-Throws {& $module {param($p)Assert-AmithOutputPath $p (Join-Path $p.OutputRoot '../escape.zip')} $p} '*escaped*'
    }
}
finally { & $module {param($Original) Set-Item Function:script:Invoke-AmithNative -Value $Original} $originalNative; $env:GH_TOKEN=$originalGhToken; $env:AMITH_TOOL_CACHE=$originalToolCache
    foreach($name in $originalSdkFunctions.Keys){& $module {param($name,$body)Set-Item "Function:script:$name" $body} $name $originalSdkFunctions[$name]}
}
. (Join-Path $PSScriptRoot 'SdkExecutionChecks.ps1')
Check 'real ZIP and tar archives honor both naming modes and preserve old saved-plan naming' {
    foreach($mode in @('unversioned','versioned','legacy')) {
        $root=Join-Path $testRoot ('archive-'+$mode)
        $source=Join-Path $root 'publish'
        [void][IO.Directory]::CreateDirectory($source)
        Set-Content -LiteralPath (Join-Path $source 'app.txt') -Value 'archive content'
        $project=@{Name='Example.Api';Archive=$true;ArchiveFormats=@('zip','tar.gz')}
        if($mode -ne 'legacy') { $project.VersionedArchives=$mode -eq 'versioned' }
        $p=@{Root=$root;OutputRoot=$root;Version='1.2.3-rc.1';Projects=@($project);Artifacts=@();Stages=@{Publish=@{Status='Succeeded'}}}
        & $module {param($p,$project,$source)Add-AmithArtifact $p PublishDirectory $project $source 'linux-x64';Invoke-AmithArchive $p} $p $project $source
        $suffix=if($mode -eq 'unversioned'){''}else{'-1.2.3-rc.1'}
        Assert-Equal @("Example.Api-linux-x64$suffix.zip","Example.Api-linux-x64$suffix.tar.gz") @($p.Artifacts|Where-Object Kind -eq Archive|ForEach-Object{Split-Path -Leaf $_.Path})
        $zip=[IO.Compression.ZipFile]::OpenRead(@($p.Artifacts|Where-Object Kind -eq Archive)[0].Path)
        try { Assert-Equal 1 @($zip.Entries|Where-Object FullName -eq 'app.txt').Count } finally {$zip.Dispose()}
        $tar=@($p.Artifacts|Where-Object Kind -eq Archive)[1].Path
        $entries=@(& $module {param($file,$root)Invoke-AmithNative tar @('-tzf',$file) $root -Capture} $tar $root)
        Assert-True (@($entries|Where-Object {$_ -match '(^|/)app\.txt$'}).Count -eq 1)
    }
}
if ($Integration) {
    Check 'real MSBuild discovery, build, NuGet pack and Windows/Linux publish' {
        $root=Join-Path $testRoot 'real';foreach($dir in @('Lib','App','Api','Desktop')){[void][IO.Directory]::CreateDirectory((Join-Path $root $dir))}
        Set-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Value '<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'Lib/Lib.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><PackageVersion>9.9.9</PackageVersion></PropertyGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'Lib/Class.cs') -Value 'public static class Example { public static int Value => 42; }'
        Set-Content -LiteralPath (Join-Path $root 'App/App.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'App/Program.cs') -Value 'System.Console.WriteLine(Example.Value);'
        Set-Content -LiteralPath (Join-Path $root 'Api/Api.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'Api/Program.cs') -Value 'var app = WebApplication.CreateBuilder(args).Build(); app.MapGet("/", () => "ok"); app.Run();'
        Set-Content -LiteralPath (Join-Path $root 'Desktop/Desktop.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0-windows</TargetFramework><UseWPF>true</UseWPF><OutputType>WinExe</OutputType></PropertyGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'Desktop/Program.cs') -Value 'internal static class Entry { [System.STAThread] public static void Main() { new System.Windows.Application().Run(); } }'
        $config=Join-Path $root 'amith.build.psd1';Set-Content -LiteralPath $config -Value '@{Discover=$false;Runtimes=@(''win-x64'',''linux-x64'');Projects=@(@{Path=''Lib/Lib.csproj'';Pack=$true},@{Path=''App/App.csproj''},@{Path=''Api/Api.csproj''},@{Path=''Desktop/Desktop.csproj'';SelfContained=$false;SingleFile=$false;SelfExtract=$false})}'
        $p=Invoke-AmithBuild -ConfigPath $config -Version '0.0.0-integration' -NoTests -PackOnlyProjects Lib -PlanPath (Join-Path $testRoot 'integration.json')
        Assert-Equal @('win-x64','linux-x64','win-x64','linux-x64','win-x64') @($p.Artifacts|Where-Object Kind -eq PublishDirectory|ForEach-Object Runtime)
        $api=@($p.Projects|Where-Object Name -eq Api)[0]
        Assert-Equal Web $api.Kind; Assert-True $api.SelfContained; Assert-True $api.SingleFile
        foreach($artifact in @($p.Artifacts|Where-Object {$_.Kind -eq 'PublishDirectory' -and $_.Project -eq 'Api'})) {
            $name=if($artifact.Runtime -like 'win-*'){'Api.exe'}else{'Api'}
            Assert-True (Test-Path -LiteralPath (Join-Path $artifact.Path $name))
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $artifact.Path 'Api.dll')))
        }
        Assert-Equal 1 @($p.Artifacts|Where-Object Kind -eq NuGet).Count;Assert-Equal 7 @($p.Artifacts|Where-Object Kind -eq Archive).Count
    }
}
if ($Integration) {
    Check 'conditional inherited RIDs and shared dependencies work for host tests with both runners' {
        $root=Join-Path $testRoot 'runtime-regression'
        foreach($dir in @('AApp','Lib','Tests')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $dir)) }
        $foreign=if($IsWindows){'linux-x64'}else{'win-x64'}
        Set-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Value ('<Project><PropertyGroup Condition="''$(TargetFramework)'' != '''' and !$(TargetFramework.Contains(''-windows''))"><RuntimeIdentifier>'+ $foreign +'</RuntimeIdentifier></PropertyGroup></Project>')
        Set-Content -LiteralPath (Join-Path $root 'Lib/Lib.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFrameworks>net10.0;net10.0-windows</TargetFrameworks></PropertyGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'Lib/Example.cs') -Value 'public static class Example { public static int Value => 42; }'
        Set-Content -LiteralPath (Join-Path $root 'AApp/AApp.csproj') -Value ('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><RuntimeIdentifier>'+ $foreign +'</RuntimeIdentifier></PropertyGroup><ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup></Project>')
        Set-Content -LiteralPath (Join-Path $root 'AApp/Program.cs') -Value 'System.Console.WriteLine(Example.Value);'
        $testProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFrameworks>net10.0;net10.0-windows</TargetFrameworks><OutputType>Exe</OutputType><IsPackable>false</IsPackable><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><PackageReference Include="xunit.v3" Version="4.0.3" /><PackageReference Include="xunit.runner.visualstudio" Version="4.0.1" /><PackageReference Include="Microsoft.NET.Test.Sdk" Version="18.12.0" /><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup></Project>'
        Set-Content -LiteralPath (Join-Path $root 'Tests/Tests.cs') -Value 'public class RuntimeTests { [Xunit.Fact] public void RunsOnHost() => Xunit.Assert.Equal(42, Example.Value); }'
        $config=Join-Path $root 'amith.build.psd1'
        Set-Content -LiteralPath $config -Value '@{Discover=$false;Projects=@(@{Path=''AApp/AApp.csproj'';Publish=$false},@{Path=''Lib/Lib.csproj'';Pack=$true},@{Path=''Tests/Tests.csproj''})}'
        foreach($runner in @('Microsoft.Testing.Platform','VSTest')) {
            # xUnit v3 is MTP-native on SDK 10. Use a genuine VSTest project for
            # that adapter rather than asking an MTP-only runner to emulate it.
            $projectXml=if($runner -eq 'VSTest') { $testProject.Replace('Include="xunit.v3" Version="4.0.3"','Include="xunit" Version="2.9.3"') } else { $testProject }
            Set-Content -LiteralPath (Join-Path $root 'Tests/Tests.csproj') -Value $projectXml
            Set-Content -LiteralPath (Join-Path $root 'global.json') -Value (@{sdk=@{version='10.0.100';rollForward='latestFeature';allowPrerelease=$false};test=@{runner=$runner}}|ConvertTo-Json -Depth 4)
            $p=Invoke-AmithBuild -ConfigPath $config -Version '0.0.0-runtime-test' -Stages Restore,Build,Test,Pack
            Assert-Equal $(if($IsWindows){2}else{1}) $p.TestResults.ExecutedTargets
            Assert-Equal 1 @($p.Artifacts|Where-Object Kind -eq NuGet).Count
        }
    }
}
if ($Integration) { . (Join-Path $PSScriptRoot 'PackagingIntegrationChecks.ps1'); . (Join-Path $PSScriptRoot 'ToolCacheIntegrationChecks.ps1'); . (Join-Path $PSScriptRoot 'SdkResolutionIntegrationChecks.ps1'); . (Join-Path $PSScriptRoot 'SdkExecutionIntegrationChecks.ps1') }
. (Join-Path $PSScriptRoot 'NuGetChecks.ps1')
. (Join-Path $PSScriptRoot 'ContainerChecks.ps1')
Write-Host "$script:passed checks passed. Test workspace: $testRoot"

exit 0
