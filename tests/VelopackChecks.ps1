# Invoked by Test-AmithBuild.ps1 while publishing tools are mocked.
function New-VelopackFixture([hashtable]$Options=@{},[string]$Version='1.2.3') {
    $state.DownloadMode='Empty';$state.SeedPackId='Amith.Client';$state.FailVpkChannel='';$state.PartialVpk=$false;$state.ReflectReleases=$false
    $p=New-FixturePlan $Version
    $desktop=@($p.Projects|Where-Object Name -eq Desktop)[0]
    $desktop.Velopack=@{Enabled=$true;ToolVersion='1.2.161';PackId='Amith.Client';Repository='Amith211/Example'}
    foreach($key in $Options.Keys){$desktop.Velopack[$key]=$Options[$key]}
    $p.Release=@{GitHub=@{Enabled=$true;Repository='Amith211/Example';RequireCleanTree=$false}}
    $p.SourceCommit='0123456789012345678901234567890123456789'
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    foreach($stage in @('Restore','Build','Test','Publish','Archive')){$p=Invoke-AmithBuildStage $p.PlanPath $stage}
    $state.Calls.Clear()
    return $p
}
function Get-VpkCalls([string]$Operation) { @($state.Calls|Where-Object{[IO.Path]::GetFileNameWithoutExtension($_.File) -eq 'vpk' -and $_.Arguments -contains $Operation}) }
Check 'Velopack defaults and added exclusions form one portable case-sensitive regex' {
    $options=@{Excludes=@('(^|[\\/])secret\.json$');PackArguments=@('--exclude','(^|[\\/])cache\.bin$','--icon','app.ico')}
    $arguments=@(& $module {param($options)Get-AmithVelopackPackArguments $options} $options)
    Assert-Equal 1 @($arguments|Where-Object{$_ -eq '--exclude'}).Count
    $pattern=$arguments[1]
    foreach($file in @('C:\publish\a.pdb','/publish/a.pdb','C:\publish\Development.json','/publish/Development.json','C:\publish\appsettings.Development.json','/publish/splash-image.png','C:\publish\splash-image.jpeg','/publish/secret.json','C:\publish\cache.bin')){Assert-True ([regex]::IsMatch($file,$pattern))}
    foreach($file in @('/publish/appsettings.json','C:\publish\Application.exe','/publish/Development.json.bak','/publish/APP.PDB')){Assert-True (-not [regex]::IsMatch($file,$pattern))}
    Assert-Equal @('--icon','app.ico') @($arguments|Select-Object -Skip 2)
}
Check 'Velopack arguments cannot replace mandatory exclusions or packaging identity' {
    foreach($value in @('--noDefaultExclude','--channel=other','--outputDir','-v')) {
        Assert-Throws {& $module {param($v)Get-AmithVelopackPackArguments @{PackArguments=@($v)}} $value} '*cannot override*'
    }
    Assert-Throws {& $module {Get-AmithVelopackPackArguments @{Excludes=@('[')}}} '*Invalid Velopack exclusion*'
    Assert-Throws {& $module {Get-AmithVelopackPackArguments @{PackArguments=@('--exclude')}}} '*requires a regex*'
}
Check 'Velopack downloads previous by default and no prior release is successful' {
    $p=New-VelopackFixture
    $p=Invoke-AmithBuildStage $p.PlanPath Installer
    Assert-Equal 1 @(Get-VpkCalls download).Count;Assert-Equal 1 @(Get-VpkCalls pack).Count
    Assert-Equal Succeeded $p.Stages.Installer.Status
    Assert-Equal 1 $p.VelopackPackages.Count
    Assert-Equal 3 @($p.Artifacts|Where-Object Kind -eq Installer).Count
}
Check 'public downloads can proceed without a token and private failures still propagate' {
    $p=New-VelopackFixture
    $token=$env:GH_TOKEN
    try {
        $env:GH_TOKEN=$null;$p=Invoke-AmithBuildStage $p.PlanPath Installer
        Assert-True (-not @(Get-VpkCalls download)[0].Arguments.Contains('--token'))
    } finally {$env:GH_TOKEN=$token}
}
Check 'Velopack download can be explicitly disabled' {
    $p=New-VelopackFixture @{DownloadPrevious=$false}
    $p=Invoke-AmithBuildStage $p.PlanPath Installer
    Assert-Equal 0 @(Get-VpkCalls download).Count;Assert-Equal 1 @(Get-VpkCalls pack).Count
}
Check 'download exceptions and zero-exit incomplete downloads prevent packing' {
    foreach($mode in @('Error','Incomplete','Corrupt')) {
        $p=New-VelopackFixture;$state.DownloadMode=$mode
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Installer}
        Assert-Equal Failed (Read-Plan $p.PlanPath).Stages.Installer.Status
        Assert-Equal 0 @(Get-VpkCalls pack).Count
    }
}
Check 'downloaded seeds enable delta packing but are not recorded as generated release assets' {
    $p=New-VelopackFixture;$state.DownloadMode='Seed'
    $p=Invoke-AmithBuildStage $p.PlanPath Installer
    Assert-True (Test-Path -LiteralPath (Join-Path $p.VelopackPackages[0].Directory 'previous-full.nupkg'))
    Assert-Equal 0 @($p.Artifacts|Where-Object{(Split-Path -Leaf $_.Path) -eq 'previous-full.nupkg'}).Count
    Assert-Equal 0 @($p.VelopackPackages[0].Files|Where-Object Name -eq 'previous-full.nupkg').Count
}
Check 'previous packages from another application are rejected' {
    $p=New-VelopackFixture;$state.DownloadMode='Seed';$state.SeedPackId='Wrong.Application'
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Installer} '*different application*'
    Assert-Equal 0 @(Get-VpkCalls pack).Count
}
Check 'failed installer attempts can retry in a fresh output directory without deleting earlier output' {
    $p=New-VelopackFixture;$state.DownloadMode='Incomplete'
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Installer} '*did not complete*'
    $first=@(Get-VpkCalls download)[0].Arguments
    $oldDirectory=$first[([array]::IndexOf($first,'--outputDir')+1)]
    $state.DownloadMode='Empty';$p=Invoke-AmithBuildStage $p.PlanPath Installer
    Assert-True (Test-Path -LiteralPath (Join-Path $oldDirectory 'failed.nupkg.incomplete'))
    Assert-Equal Succeeded $p.Stages.Installer.Status
}
Check 'colliding channels fail before invoking packaging or download tools' {
    $p=New-VelopackFixture
    @($p.Projects|Where-Object Name -eq Api)[0].Velopack=@{Enabled=$true;ToolVersion='1.2.161'}
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Installer} '*distinct channels*'
    Assert-Equal 0 $state.Calls.Count
}
Check 'GitHub draft receives archives through gh and Velopack assets through merge before publication' {
    $p=New-VelopackFixture;$p=Invoke-AmithBuildStage $p.PlanPath Installer;$state.Calls.Clear()
    $p=Invoke-AmithBuildStage $p.PlanPath Release
    $uploads=@(Get-VpkCalls upload);Assert-Equal 1 $uploads.Count
    $call=$uploads[0];Assert-True ($call.Arguments -contains '--merge');Assert-True (-not ($call.Arguments -contains '--publish'))
    Assert-Equal v1.2.3 $call.Arguments[([array]::IndexOf($call.Arguments,'--tag')+1)]
    Assert-Equal $p.SourceCommit $call.Arguments[([array]::IndexOf($call.Arguments,'--targetCommitish')+1)]
    Assert-True ($call.SensitiveValues -contains 'not-a-real-test-token')
    $ghUpload=@($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[0] -eq 'release' -and $_.Arguments[1] -eq 'upload'})[0]
    foreach($file in @($p.Artifacts|Where-Object Kind -eq Installer)){Assert-True (-not ($ghUpload.Arguments -contains $file.Path))}
    $calls=@($state.Calls);$uploadIndex=[array]::IndexOf($calls,$call);$archiveIndex=[array]::IndexOf($calls,$ghUpload)
    $edit=@($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[1] -eq 'edit'})[0]
    Assert-True ($archiveIndex -lt $uploadIndex);Assert-True ($uploadIndex -lt [array]::IndexOf($calls,$edit))
    Assert-True (-not $state.Remote.draft)
}
Check 'Velopack-only releases do not require a generic gh asset upload' {
    $p=New-VelopackFixture;$p=Invoke-AmithBuildStage $p.PlanPath Installer
    $p.Artifacts=@($p.Artifacts|Where-Object Kind -ne Archive)
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    $state.Calls.Clear();$p=Invoke-AmithBuildStage $p.PlanPath Release
    Assert-Equal 1 @(Get-VpkCalls upload).Count
    Assert-Equal 0 @($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[1] -eq 'upload'}).Count
}
Check 'partial upload retains draft and retry reports its conflicting assets without overwriting them' {
    $p=New-VelopackFixture;$p=Invoke-AmithBuildStage $p.PlanPath Installer
    $state.FailVpkChannel='win';$state.PartialVpk=$true
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*Velopack upload failure*'
    Assert-True $state.Remote.draft;Assert-Equal 1 $state.Remote.assets.Count
    $state.ReflectReleases=$true;$state.FailVpkChannel='';$state.Calls.Clear()
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*Partial or conflicting Velopack upload*'
    Assert-Equal 0 @(Get-VpkCalls upload).Count
    Assert-Equal 0 @($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[1] -eq 'edit'}).Count
}
Check 'completed channel is verified and skipped while a channel with no uploaded assets retries' {
    $p=New-VelopackFixture
    @($p.Projects|Where-Object Name -eq Desktop)[0].Velopack.Enabled=$false
    @($p.Projects|Where-Object Name -eq Api)[0].Velopack=@{Enabled=$true;ToolVersion='1.2.161';Repository='Amith211/Example';Channels=@{'win-x64'='win';'linux-x64'='linux'}}
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    $p=Invoke-AmithBuildStage $p.PlanPath Installer
    $state.FailVpkChannel='linux'
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*Velopack upload failure*'
    Assert-Equal Succeeded (Read-Plan $p.PlanPath).VelopackUploads['Amith211/Example|v1.2.3|win'].Status
    $state.FailVpkChannel='';$state.ReflectReleases=$true;$state.Calls.Clear()
    $p=Invoke-AmithBuildStage $p.PlanPath Release
    $uploads=@(Get-VpkCalls upload);Assert-Equal 1 $uploads.Count
    Assert-Equal linux $uploads[0].Arguments[([array]::IndexOf($uploads[0].Arguments,'--channel')+1)]
    Assert-True (-not $state.Remote.draft)
}
Check 'configured drafts stay draft and changed completed remote assets block retry' {
    $p=New-VelopackFixture;$p.Release.GitHub.Draft=$true
    & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
    $p=Invoke-AmithBuildStage $p.PlanPath Installer;$p=Invoke-AmithBuildStage $p.PlanPath Release
    Assert-True $state.Remote.draft
    $state.ReflectReleases=$true;$state.Calls.Clear();$p=Invoke-AmithBuildStage $p.PlanPath Release
    Assert-Equal 0 @(Get-VpkCalls upload).Count
    $state.Remote.assets[0].size++
    Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*changed or are missing*'
}
Check 'prerelease downloads uploads and GitHub metadata use the same version policy' {
    $p=New-VelopackFixture @{} '1.2.3-beta.1';$p=Invoke-AmithBuildStage $p.PlanPath Installer
    Assert-True @(Get-VpkCalls download)[0].Arguments.Contains('--pre')
    $p=Invoke-AmithBuildStage $p.PlanPath Release
    Assert-True @(Get-VpkCalls upload)[0].Arguments.Contains('--pre')
    Assert-True @($state.Calls|Where-Object{$_.File -eq 'gh' -and $_.Arguments[1] -eq 'create'})[0].Arguments.Contains('--prerelease')
}

Check 'draft lookup resolves release ID instead of the by-tag endpoint that hides drafts' {
    $p=New-VelopackFixture
    $state.Remote=@{tag_name='v1.2.3';draft=$true;assets=@()}
    $state.Calls.Clear()
    $draft=& $module {param($p)Get-AmithGitHubDraft $p 'Amith211/Example' 'v1.2.3'} $p
    Assert-True $draft.draft
    $calls=@($state.Calls)
    Assert-Equal @('release','view','v1.2.3','--repo','Amith211/Example','--json','apiUrl') $calls[0].Arguments
    Assert-Equal @('api','https://api.github.com/repos/Amith211/Example/releases/42') $calls[1].Arguments
}
Check 'draft-aware lookup still rejects published or mismatched releases' {
    $p=New-VelopackFixture
    foreach($remote in @(@{tag_name='v1.2.3';draft=$false;assets=@()},@{tag_name='v9.0.0';draft=$true;assets=@()})) {
        $state.Remote=$remote
        Assert-Throws {& $module {param($p)Get-AmithGitHubDraft $p 'Amith211/Example' 'v1.2.3'} $p} '*expected GitHub draft*'
    }
}

# Do not leak scenario state into the parent suite.
$state.DownloadMode='Empty';$state.FailVpkChannel='';$state.PartialVpk=$false;$state.ReflectReleases=$false
