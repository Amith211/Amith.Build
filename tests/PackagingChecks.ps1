# Invoked with native publishing tools mocked; filesystem operations are real.
Check 'package globs match relative paths consistently without project-name shortcuts' {
    foreach ($pair in @(@('a.txt','**/*.txt'),@('a/b.TXT','**/*.txt'),@('a/x1.txt','a/x?.txt'),@('cache/sub/file','cache/**'))) {
        Assert-True (& $module {param($path,$pattern) Test-AmithPackagePattern $path $pattern} ($pair[0]) ($pair[1]))
    }
    foreach ($pair in @(@('a/b.txt','*.txt'),@('other/cache/file','cache/**'),@('ax.txt','a?.json'))) {
        Assert-True (-not (& $module {param($path,$pattern) Test-AmithPackagePattern $path $pattern} ($pair[0]) ($pair[1])))
    }
    foreach ($invalidGlob in @('','../secret','a/../secret','C:/secret','/secret')) {
        Assert-Throws {& $module {param($pattern) Assert-AmithPackagePattern $pattern} $invalidGlob} '*relative glob*'
    }
}
Check 'package policy defaults and additive configuration survive CLI forwarding' {
    $p=New-FixturePlan
    foreach($project in $p.Projects) {Assert-True $project.IncludeSymbols;Assert-True (-not $project.IncludeDevelopmentSettings)}
    $config=Join-Path $fixture 'package-options.psd1'
    Set-Content -LiteralPath $config -Value '@{Discover=$false;Defaults=@{IncludeSymbols=$false;IncludeDevelopmentSettings=$true;PackageExcludes=@(''default/**'')};Projects=@(@{Path=''src/Api/Api.csproj'';PackageExcludes=@(''project/**'')});Overrides=@(@{Match=''Api'';PackageExcludes=@(''override/**'')})}'
    $p=Invoke-AmithBuild -ConfigPath $config -Version 1.2.3 -PlanOnly -IncludeSymbols:$true -IncludeDevelopmentSettings:$false -PackageExcludes 'cli/**'
    Assert-True $p.Projects[0].IncludeSymbols;Assert-True (-not $p.Projects[0].IncludeDevelopmentSettings)
    Assert-Equal @('default/**','project/**','override/**','cli/**') $p.Projects[0].PackageExcludes
    $p=Invoke-AmithBuild -ConfigPath $config -Version 1.2.3 -PlanOnly -IncludeSymbols:$false -IncludeDevelopmentSettings:$true
    Assert-True (-not $p.Projects[0].IncludeSymbols);Assert-True $p.Projects[0].IncludeDevelopmentSettings
}
function New-PackageContentFixture {
    param([hashtable]$Settings=@{})
    $root=Join-Path $testRoot ('contents-'+[guid]::NewGuid().ToString('N'));$source=Join-Path $root 'publish'
    foreach($path in @('app.exe','app.pdb','library.PDB','appsettings.json','appsettings.Development.json','nested/Development.json','nested/APPSETTINGS.DEVELOPMENT.JSON','swagger.json','web.config','app.staticwebassets.endpoints.json','.hidden-config','images/splash-image.png','data/custom.bin','scratch/remove.txt')) {
        $file=Join-Path $source $path;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $file));Set-Content -LiteralPath $file -Value 'fixture content'
    }
    $project=@{Name='Amith.App';Archive=$true;ArchiveFormats=@('zip');VersionedArchives=$false}
    foreach($key in $Settings.Keys){$project[$key]=$Settings[$key]}
    $p=@{Root=$root;OutputRoot=$root;Version='1.2.3';Projects=@($project);Stages=@{Publish=@{Status='Succeeded'}};Artifacts=@()}
    & $module {param($p,$project,$source)Add-AmithArtifact $p PublishDirectory $project $source 'win-x64'} $p $project $source
    return $p
}
Check 'prepared packages exclude development files and preserve symbols and arbitrary runtime content' {
    $p=New-PackageContentFixture @{PackageExcludes=@('scratch/**')}
    & $module {param($p)Invoke-AmithArchive $p} $p
    $prepared=$p.PackageInputs['Amith.App|win-x64']
    Assert-Equal 4 @($prepared.Files|Where-Object {-not $_.Included}).Count
    Assert-True (Test-Path -LiteralPath (Join-Path $p.Artifacts[0].Path 'appsettings.Development.json'))
    $zip=[IO.Compression.ZipFile]::OpenRead($p.Artifacts[1].Path)
    try {
        $names=@($zip.Entries.FullName)
        foreach($name in @('app.pdb','library.PDB','appsettings.json','swagger.json','web.config','app.staticwebassets.endpoints.json','.hidden-config','images/splash-image.png','data/custom.bin')){Assert-True ($names -contains $name)}
        Assert-Equal 10 $names.Count
    } finally {$zip.Dispose()}
    # A persisted plan and a second packaging route reuse identical inputs.
    $saved=Join-Path $p.Root 'saved.json'; & $module {param($p,$saved)Write-AmithJson $p $saved} $p $saved
    $p=Read-Plan $saved
    $reused=& $module {param($p)Get-AmithPackageInput $p $p.Projects[0] $p.Artifacts[0]} $p
    Assert-Equal $prepared.Directory $reused.Directory
}
Check 'symbol opt-out and development opt-in are independent and additional globs still win' {
    $p=New-PackageContentFixture @{IncludeSymbols=$false;IncludeDevelopmentSettings=$true;PackageExcludes=@('nested/**')}
    $prepared=& $module {param($p)Get-AmithPackageInput $p $p.Projects[0] $p.Artifacts[0]} $p
    Assert-True (Test-Path -LiteralPath (Join-Path $prepared.Directory 'appsettings.Development.json'))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $prepared.Directory 'app.pdb')))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $prepared.Directory 'library.PDB')))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $prepared.Directory 'nested/Development.json')))
    $args=& $module {Get-AmithVelopackPackArguments @{} $true}
    Assert-True (-not [regex]::IsMatch('appsettings.Development.json',$args[1]))
    Assert-True ([regex]::IsMatch('app.pdb',$args[1]));Assert-True ([regex]::IsMatch('splash-image.png',$args[1]))
}
Check 'changed raw or prepared package input fails closed' {
    foreach($target in @('source','prepared')) {
        $p=New-PackageContentFixture
        $prepared=& $module {param($p)Get-AmithPackageInput $p $p.Projects[0] $p.Artifacts[0]} $p
        $directory=if($target -eq 'source'){$p.Artifacts[0].Path}else{$prepared.Directory}
        Set-Content -LiteralPath (Join-Path $directory 'app.exe') -Value 'changed content'
        Assert-Throws {& $module {param($p)Get-AmithPackageInput $p $p.Projects[0] $p.Artifacts[0]} $p} '*changed*'
    }
}
if(-not $IsWindows) {
    Check 'publish links cannot include content outside the package tree' {
        $p=New-PackageContentFixture;$outside=Join-Path $testRoot 'outside.txt';Set-Content -LiteralPath $outside -Value 'outside'
        New-Item -ItemType SymbolicLink -Path (Join-Path $p.Artifacts[0].Path 'linked.txt') -Target $outside | Out-Null
        Assert-Throws {& $module {param($p)Get-AmithPackageInput $p $p.Projects[0] $p.Artifacts[0]} $p} '*symbolic link*'
    }
}
Check 'Velopack shares prepared archive inputs and keeps its independent PDB exclusion' {
    # Prepare content before either packaging route runs.
    $p=New-PackageContentFixture
    $p.Projects[0].Velopack=@{Enabled=$true;ToolVersion='1.2.161';PackId='Amith.Client';Repository='Amith211/Example';DownloadPrevious=$false}
    $p.Projects[0].AssemblyName='app';$p.Projects[0].ProjectAssetsFile=''
    $p.Release=@{};$p.PlanPath=Join-Path $p.Root 'plan.json';$p.SchemaVersion='1alpha1'
    & $module {param($p)Write-AmithJson $p $p.PlanPath;Invoke-AmithArchive $p;Write-AmithJson $p $p.PlanPath} $p
    $state.Calls.Clear();$p=Invoke-AmithBuildStage $p.PlanPath Installer
    $call=@(Get-VpkCalls pack)[0];$dir=$call.Arguments[([array]::IndexOf($call.Arguments,'--packDir')+1)]
    Assert-Equal $p.PackageInputs['Amith.App|win-x64'].Directory $dir
    Assert-True (Test-Path -LiteralPath (Join-Path $dir 'app.pdb'))
    Assert-True ([regex]::IsMatch('app.pdb',$call.Arguments[([array]::IndexOf($call.Arguments,'--exclude')+1)]))
}
Check 'repository mismatch is rejected before any previous download or tool installation' {
    $p=New-VelopackFixture @{Repository='Amith211/Different'}
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Installer} '*repositories differ*'
    Assert-Equal 0 $state.Calls.Count
}
Check 'retention copies only verified recorded artifacts and excludes downloaded seeds and stray files' {
    $p=New-VelopackFixture;$state.DownloadMode='Seed';$p=Invoke-AmithBuildStage $p.PlanPath Installer
    $stray=Join-Path $p.VelopackPackages[0].Directory 'stray.nupkg';Set-Content -LiteralPath $stray -Value 'must not upload'
    $p=Invoke-AmithBuildStage $p.PlanPath Retain
    $retained=@(Get-ChildItem -LiteralPath $p.RetainedRoot -Recurse -File)
    Assert-Equal @($p.Artifacts|Where-Object Kind -in Archive,Installer,NuGet,Symbols).Count $retained.Count
    Assert-True (-not @($retained|Where-Object Name -in 'previous-full.nupkg','stray.nupkg','plan.json').Count)
    $p=Invoke-AmithBuildStage $p.PlanPath Installer
    Assert-True (-not $p.Contains('RetainedRoot'));Assert-True (-not $p.Stages.Contains('Retain'))
    $file=@($p.Artifacts|Where-Object Kind -eq Installer)[0];Set-Content -LiteralPath $file.Path -Value 'tampered'
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Retain} '*missing or changed*'
    $failed=Read-Plan $p.PlanPath;Assert-True (-not $failed.Contains('RetainedRoot'));Assert-Equal Failed $failed.Stages.Retain.Status
}
