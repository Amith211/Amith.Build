Import-Module (Join-Path $PSScriptRoot '../src/Amith.Build/Amith.Build.psd1') -Force
$module = Get-Module Amith.Build
# Container checks use real OCI archives and fake external build/registry commands.
function New-ContainerTestArchive {
    param([string] $Path, [string[]] $Platforms = @('linux/amd64'), [switch] $CorruptBlob, [switch] $MissingBlob)
    Add-Type -AssemblyName System.Formats.Tar
    $blobs = @{}; $manifests = @()
    function Add-TestBlob([string] $Text) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $blobs[$hash] = $bytes
        return @{digest="sha256:$hash";size=$bytes.Length}
    }
    foreach ($platform in $Platforms) {
        $parts = $platform.Split('/')
        $config = Add-TestBlob (@{architecture=$parts[1];os=$parts[0];config=@{};rootfs=@{type='layers';diff_ids=@()}} | ConvertTo-Json -Depth 10 -Compress)
        $config.mediaType = 'application/vnd.oci.image.config.v1+json'
        $layer = Add-TestBlob 'fixture layer'
        $layer.mediaType = 'application/vnd.oci.image.layer.v1.tar'
        $manifest = Add-TestBlob (@{schemaVersion=2;mediaType='application/vnd.oci.image.manifest.v1+json';config=$config;layers=@($layer)} | ConvertTo-Json -Depth 10 -Compress)
        $manifest.mediaType = 'application/vnd.oci.image.manifest.v1+json'; $manifest.platform = @{os=$parts[0];architecture=$parts[1]}
        $manifests += $manifest
    }
    if ($manifests.Count -eq 1) { $root = $manifests[0] }
    else {
        $root = Add-TestBlob (@{schemaVersion=2;mediaType='application/vnd.oci.image.index.v1+json';manifests=$manifests} | ConvertTo-Json -Depth 15 -Compress)
        $root.mediaType = 'application/vnd.oci.image.index.v1+json'
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $stream = [IO.File]::Create($Path); $writer = [System.Formats.Tar.TarWriter]::new($stream,$true)
    function Write-TestEntry([string] $Name, [byte[]] $Bytes) {
        $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,$Name)
        $data = [IO.MemoryStream]::new($Bytes,$false)
        try { $entry.DataStream = $data; $writer.WriteEntry($entry) } finally { $data.Dispose() }
    }
    try {
        Write-TestEntry 'oci-layout' ([Text.Encoding]::UTF8.GetBytes('{"imageLayoutVersion":"1.0.0"}'))
        Write-TestEntry 'index.json' ([Text.Encoding]::UTF8.GetBytes((@{schemaVersion=2;manifests=@($root)} | ConvertTo-Json -Depth 15 -Compress)))
        $first = $true
        foreach ($key in $blobs.Keys) {
            if ($first -and $MissingBlob) { $first=$false; continue }
            $bytes = $blobs[$key]
            if ($first -and $CorruptBlob) { $bytes = [Text.Encoding]::UTF8.GetBytes('corrupt') }
            Write-TestEntry "blobs/sha256/$key" $bytes
            $first = $false
        }
    } finally { $writer.Dispose(); $stream.Dispose() }
    return $root.digest
}
$containerRoot = Join-Path $testRoot 'containers'
[void][IO.Directory]::CreateDirectory($containerRoot)
Set-Content -LiteralPath (Join-Path $containerRoot 'Dockerfile') -Value 'FROM scratch'
$containerConfig = @{Containers=@(@{Name='api';Image='harbor.example.com/project/api';Platforms=@('linux/amd64','linux/arm64')})}
$containerPlans = @(& $module { param($c,$root) Get-AmithContainerPlans $c $root '1.2.3' } $containerConfig $containerRoot)
Check 'container planning resolves defaults, paths, version and secret references' {
    Assert-Equal 1 $containerPlans.Count
    Assert-Equal '1.2.3' $containerPlans[0].Tag
    Assert-Equal 'harbor.example.com' $containerPlans[0].Registry
    Assert-Equal $containerRoot $containerPlans[0].Context
    $config = @{Containers=@(@{Name='api';Image='harbor.example.com/project/api';Secrets=@(@{Id='token';Source='Environment';Environment='BUILD_TOKEN'})})}
    $p = @(& $module {param($c,$r)Get-AmithContainerPlans $c $r '1.2.3'} $config $containerRoot)[0]
    Assert-Equal 'BUILD_TOKEN' $p.Secrets[0].Environment
}
Check 'invalid image names, duplicate outputs, escaping paths and malformed secrets fail planning' {
    foreach ($change in @(
        @{Image='https://harbor.example.com/project/api'}, @{Image='harbor.example.com/project/api:tag'},
        @{Image='Harbor.example.com/project/api'}, @{Tag='latest'}, @{Tag='bad+tag'},
        @{Context='..'}, @{Dockerfile='../Dockerfile'}, @{Platforms=@('windows/amd64')},
        @{Platforms=@('linux/amd64','linux/amd64')}, @{BuildArguments=@{AMITH_VERSION='override'}},
        @{Secrets=@(@{Id='token';Source='Environment';Environment='bad-name'})}, @{Unknown='setting'}
    )) {
        $entry = @{Name='api';Image='harbor.example.com/project/api'}
        foreach ($key in $change.Keys) { $entry[$key]=$change[$key] }
        Assert-Throws { & $module {param($c,$r)Get-AmithContainerPlans $c $r '1.2.3'} @{Containers=@($entry)} $containerRoot }
    }
    $duplicate=@{Containers=@($containerConfig.Containers[0],$containerConfig.Containers[0])}
    Assert-Throws {& $module {param($c,$r)Get-AmithContainerPlans $c $r '1.2.3'} $duplicate $containerRoot} '*unique*'
    Assert-Throws {& $module {Assert-AmithContainerReleaseOptions @{TagAsLatest='maybe'}}} '*Boolean*'
}
Check 'OCI validation verifies manifests, platforms and every blob without extraction' {
    $path=Join-Path $containerRoot 'valid.oci.tar'
    $digest=New-ContainerTestArchive $path @('linux/amd64','linux/arm64')
    $image=& $module {param($p)Read-AmithOciArchive $p @('linux/amd64','linux/arm64')} $path
    Assert-Equal $digest $image.Digest
    Assert-Throws {& $module {param($p)Read-AmithOciArchive $p @('linux/amd64')} $path} '*platforms*'
    [void](New-ContainerTestArchive $path -CorruptBlob)
    Assert-Throws {& $module {param($p)Read-AmithOciArchive $p @('linux/amd64')} $path} '*digest*'
    [void](New-ContainerTestArchive $path -MissingBlob)
    Assert-Throws {& $module {param($p)Read-AmithOciArchive $p @('linux/amd64')} $path} '*missing*'
}
$containerOriginals=@{}
foreach ($name in @('Invoke-AmithNative','Get-AmithRegistryDigest')) { $containerOriginals[$name]=& $module {param($n)(Get-Item "Function:$n").ScriptBlock} $name }
$containerState=@{Calls=[Collections.Generic.List[object]]::new();Remote=@{};Digest='';FailCopy=$false;FailLatest=$false;Mismatch=$false;FailBuild=$false;NuGetText='';SecretPath='';ArchiveFactory=${function:New-ContainerTestArchive}}
$oldContainerSources=$env:AMITH_NUGET_RESTORE_SOURCES
try {
    & $module {
        param($state)
        $script:ContainerTestState=$state
        function script:Get-AmithRegistryDigest {param($Reference) if($script:ContainerTestState.Remote.ContainsKey($Reference)){return $script:ContainerTestState.Remote[$Reference]};return ''}
        function script:Invoke-AmithNative {
            param($File,$Arguments,$WorkingDirectory,[switch]$Capture,$SensitiveValues)
            $s=$script:ContainerTestState
            $s.Calls.Add(@{File=$File;Arguments=@($Arguments)})
            if ($Arguments -contains '--version' -or $Arguments -contains 'version') { return 'test-tool 1.0' }
            if ($File -eq 'docker') {
                if ($Arguments -contains '--push' -or $Arguments -contains '--load') { throw 'Container must not push or load.' }
                $out=$Arguments[([array]::IndexOf($Arguments,'--output')+1)]
                $archive=$out.Substring('type=oci,dest='.Length)
                if ($Arguments -contains '--secret') {
                    $secret=$Arguments[([array]::IndexOf($Arguments,'--secret')+1)]
                    if($secret -match ',src=(.*)$'){$s.SecretPath=$Matches[1];$s.NuGetText=[IO.File]::ReadAllText($s.SecretPath)}
                }
                if ($s.FailBuild) { throw 'simulated container build failure' }
                $s.Digest=& $s.ArchiveFactory $archive @('linux/amd64','linux/arm64')
            } elseif ($File -eq 'skopeo' -and $Arguments[0] -eq 'copy') {
                $destination=$Arguments[-1].Substring('docker://'.Length)
                if ($s.FailCopy -or ($s.FailLatest -and $destination.EndsWith(':latest'))) { throw 'simulated registry failure' }
                $s.Remote[$destination]=if($s.Mismatch){'sha256:'+('f'*64)}else{$s.Digest}
            } else { throw "Unexpected test command: $File" }
        }
    } $containerState
    function New-ContainerTestPlan {
        $id=[guid]::NewGuid().ToString('N')
        $p=@{SchemaVersion='1alpha1';Root=$containerRoot;Version='1.2.3';ExplicitVersion=$true;SourceCommit='fixture';Configuration='Release';Containers=$containerPlans;Artifacts=@();Projects=@();Stages=@{Build=@{Status='Succeeded'};Test=@{Status='Succeeded'}};TestPolicy=@{NoTests=$true;SkipTests=$false};TestResults=@{Disposition='NoTests';ExecutedTargets=0};Release=@{Containers=@{Enabled=$true;TagAsLatest=$true}};PlanPath=(Join-Path $containerRoot "$id.json");OutputRoot=(Join-Path $containerRoot $id)}
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        return $p
    }
    Check 'container stage exports an OCI artifact after tests and never pushes' {
        $p=New-ContainerTestPlan
        $p=Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test
        Assert-Equal 1 $p.Artifacts.Count
        Assert-Equal 'ContainerArchive' $p.Artifacts[0].Kind
        Assert-Equal $containerState.Digest $p.Artifacts[0].Digest
        Assert-Equal 'Succeeded' $p.Stages.Container.Status
        Assert-Equal 0 @($containerState.Calls|Where-Object File -eq skopeo).Count
        $script:containerBuilt=$p
    }
    Check 'failed tests prevent any container build or publication' {
        $p=New-ContainerTestPlan;$p.Stages.Test.Status='Failed'
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $containerState.Calls.Clear()
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test} '*Test*'
        Assert-Equal 0 $containerState.Calls.Count
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*Test*'
        Assert-Equal 0 $containerState.Calls.Count
    }
    Check 'container-only release publishes version then latest with all platforms and matching digests' {
        $containerState.Calls.Clear();$containerState.Remote.Clear()
        $p=Invoke-AmithBuildStage $script:containerBuilt.PlanPath Release
        $copies=@($containerState.Calls|Where-Object {$_.File -eq 'skopeo' -and $_.Arguments[0] -eq 'copy'})
        Assert-Equal 2 $copies.Count
        Assert-True ($copies[0].Arguments -contains '--all');Assert-True ($copies[0].Arguments -contains '--preserve-digests')
        Assert-Equal 'docker://harbor.example.com/project/api:1.2.3' $copies[0].Arguments[-1]
        Assert-Equal 'docker://harbor.example.com/project/api:latest' $copies[1].Arguments[-1]
        Assert-Equal 2 $p.ContainerPublications.Count
        $containerState.Calls.Clear();[void](Invoke-AmithBuildStage $p.PlanPath Release)
        Assert-Equal 0 @($containerState.Calls|Where-Object {$_.Arguments[0] -eq 'copy'}).Count
    }
    Check 'TagAsLatest false publishes only the immutable version tag' {
        $p=Read-Plan $script:containerBuilt.PlanPath;$p.Release.Containers.TagAsLatest=$false
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $containerState.Remote.Clear();$containerState.Calls.Clear()
        [void](Invoke-AmithBuildStage $p.PlanPath Release)
        Assert-Equal 1 @($containerState.Calls|Where-Object {$_.Arguments[0] -eq 'copy'}).Count
        Assert-True (-not $containerState.Remote.ContainsKey('harbor.example.com/project/api:latest'))
    }
    Check 'conflicting version tags fail without overwriting or moving latest' {
        $containerState.Remote['harbor.example.com/project/api:1.2.3']='sha256:'+('0'*64)
        $containerState.Calls.Clear()
        Assert-Throws {Invoke-AmithBuildStage $script:containerBuilt.PlanPath Release} '*different image*'
        Assert-Equal 0 @($containerState.Calls|Where-Object {$_.Arguments[0] -eq 'copy'}).Count
    }
    Check 'failed latest publication preserves version progress and can be retried' {
        $p=Read-Plan $script:containerBuilt.PlanPath;$p.Release.Containers.TagAsLatest=$true
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $containerState.Remote.Clear();$containerState.FailLatest=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*simulated*'} finally {$containerState.FailLatest=$false}
        $p=Read-Plan $p.PlanPath
        Assert-True (@($p.ContainerPublications|Where-Object Reference -eq 'harbor.example.com/project/api:1.2.3').Count -eq 1)
        $containerState.Calls.Clear();$p=Invoke-AmithBuildStage $p.PlanPath Release
        $copies=@($containerState.Calls|Where-Object {$_.Arguments[0] -eq 'copy'})
        Assert-Equal 1 $copies.Count;Assert-True ($copies[0].Arguments[-1].EndsWith(':latest'))
    }
    Check 'container archives participate in verified artifact retention' {
        $p=Invoke-AmithBuildStage $script:containerBuilt.PlanPath Retain
        $files=@(Get-ChildItem -LiteralPath $p.RetainedRoot -Recurse -File)
        Assert-Equal 1 $files.Count
        Assert-Equal $p.Artifacts[0].SHA256 (Get-FileHash -LiteralPath $files[0].FullName -Algorithm SHA256).Hash
    }
    Check 'tampered archives block Release and Retain' {
        $p=New-ContainerTestPlan;$p=Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test
        Add-Content -LiteralPath $p.Artifacts[0].Path -Value 'tamper'
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*missing or changed*'
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Retain} '*missing or changed*'
    }
    Check 'NuGet container secrets are materialized, never saved in plans and removed after building' {
        $env:AMITH_NUGET_RESTORE_SOURCES='[{"name":"Private","url":"https://nuget.example.com/v3/index.json","username":"fixture-user","password":"fixture-password"}]'
        $p=New-ContainerTestPlan
        $p.Containers=@($containerPlans[0].Clone());$p.Containers[0].Secrets=@(@{Id='nuget_config';Source='NuGetRestoreSources';Environment=''})
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $p=Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test
        Assert-True ($containerState.NuGetText.Contains('fixture-password'))
        Assert-True (-not (Test-Path -LiteralPath $containerState.SecretPath))
        Assert-True (-not ([IO.File]::ReadAllText($p.PlanPath).Contains('fixture-password')))
        Assert-Throws {& $module {Assert-AmithContainerReleaseOptions @{MoveLatest=$true}}} '*Unknown*'
    }
    Check 'failed builds remove materialized secrets and cannot release partial output' {
        $p=New-ContainerTestPlan
        $p.Containers=@($containerPlans[0].Clone());$p.Containers[0].Secrets=@(@{Id='nuget_config';Source='NuGetRestoreSources';Environment=''})
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $containerState.FailBuild=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test} '*simulated*'} finally {$containerState.FailBuild=$false}
        Assert-True (-not (Test-Path -LiteralPath $containerState.SecretPath))
        $p=Read-Plan $p.PlanPath
        Assert-Equal 'Failed' $p.Stages.Container.Status;Assert-Equal 0 $p.Artifacts.Count
        Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*Container*'
    }
    Check 'registry copy failure and mismatched destination digests fail Release' {
        $p=New-ContainerTestPlan;$p=Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test
        $containerState.Remote.Clear();$containerState.FailCopy=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*simulated*'} finally {$containerState.FailCopy=$false}
        Assert-True (-not $containerState.Remote.ContainsKey('harbor.example.com/project/api:latest'))
        $containerState.Mismatch=$true
        try {Assert-Throws {Invoke-AmithBuildStage $p.PlanPath Release} '*digest verification*'} finally {$containerState.Mismatch=$false}
        Assert-Equal 'Failed' (Read-Plan $p.PlanPath).Stages.Release.Status
    }
    Check 'repackaging containers invalidates retention and release while preserving publication history' {
        $p=Read-Plan $script:containerBuilt.PlanPath
        Assert-True $p.Stages.Contains('Retain')
        $p=Invoke-AmithBuildStage $p.PlanPath Container -ContainerBuilder remote-test
        Assert-True (-not $p.Stages.Contains('Release'));Assert-True (-not $p.Stages.Contains('Retain'))
        Assert-Equal 1 $p.Artifacts.Count
        Assert-True ($p.ContainerPublications.Count -gt 0)
    }
    Check 'consumers without containers need no builder or container tools' {
        $p=New-ContainerTestPlan;$p.Containers=@();$p.Stages=@{}
        & $module {param($p)Write-AmithJson $p $p.PlanPath} $p
        $containerState.Calls.Clear();$p=Invoke-AmithBuildStage $p.PlanPath Container
        Assert-Equal 'Succeeded' $p.Stages.Container.Status;Assert-Equal 0 $containerState.Calls.Count
    }
} finally {
    foreach ($name in $containerOriginals.Keys) { & $module {param($n,$body)Set-Item "Function:script:$n" $body} $name $containerOriginals[$name] }
    $env:AMITH_NUGET_RESTORE_SOURCES=$oldContainerSources
}
Check 'registry manifest hashing preserves exact UTF8 bytes and rejects auth network and TLS errors' {
    $original = & $module {(Get-Item Function:Invoke-AmithRegistryInspect).ScriptBlock}
    try {
        $probe=@{ExitCode=0;Output="{`"schemaVersion`":2,`"label`":`"caf$([char]0xe9)`"}`n";Error=''}
        & $module {param($p)$script:RegistryProbe=$p;function script:Invoke-AmithRegistryInspect {param($Reference)return $script:RegistryProbe}} $probe
        $expected='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($probe.Output))).ToLowerInvariant())
        Assert-Equal $expected (& $module {Get-AmithRegistryDigest 'harbor.example.com/project/api:1.2.3'})
        $probe.ExitCode=1
        foreach($message in @('unauthorized','x509: certificate signed by unknown authority','connection refused','unexpected 404 page not found','unknown: artifact project/other:1.2.3 not found','unknown: artifact project/api:1.2.30 not found','unauthorized: artifact project/api:1.2.3 not found')) {
            $probe.Error=$message
            Assert-Throws {& $module {Get-AmithRegistryDigest 'harbor.example.com/project/api:1.2.3'}} '*Could not inspect*'
        }
        foreach($message in @('manifest unknown','unknown: artifact project/api:1.2.3 not found','time="2026-11-21T13:15:12Z" level=fatal msg="reading manifest 1.2.3 in harbor.example.com/project/api: unknown: artifact project/api:1.2.3 not found"')) {
            $probe.Error=$message
            Assert-Equal '' (& $module {Get-AmithRegistryDigest 'harbor.example.com/project/api:1.2.3'})
        }
    } finally {& $module {param($body)Set-Item Function:script:Invoke-AmithRegistryInspect $body} $original}
}
