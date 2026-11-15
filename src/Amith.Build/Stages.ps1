function Assert-AmithStage {
    param($Plan, [string] $Stage)
    $record = Get-AmithValue $Plan.Stages $Stage @{}
    if ((Get-AmithValue $record 'Status' '') -ne 'Succeeded') { throw "Run a successful $Stage stage before this operation." }
}

function Get-AmithBuildRoots {
    param($Plan)
    foreach ($project in $Plan.Projects) {
        if ($project.Kind -eq 'Test' -and @($project.TestFrameworks).Count -eq 0) { continue }
        $project
    }
}

# Tests execute on this host; requested publish RIDs are a separate concern.
function Get-AmithTestArguments {
    param([string] $Framework)
    return @("-p:TargetFramework=$Framework", '--runtime', [Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier)
}

function Get-AmithProjectBuildArguments {
    param($Plan, $Project)
    $arguments = @(Get-AmithBuildArguments $Plan)
    if ($Project.Kind -eq 'Library') {
        # A library's portable build/package must not inherit an app publish RID,
        # including a conditional RID that only appears in inner TFM evaluations.
        $arguments += @('-p:RuntimeIdentifier=', '-p:RuntimeIdentifiers=', '-p:SelfContained=false')
    }
    return $arguments
}

function Invoke-AmithProjectRestore {
    param($Plan, $Project, [string] $Framework)
    $properties = @(Get-AmithProjectBuildArguments $Plan $Project)
    # dotnet restore accepts Configuration as an MSBuild property, not -c.
    $arguments = @('restore', $Project.Path, "-p:Configuration=$($Plan.Configuration)") + @($properties | Select-Object -Skip 2)
    if ($Framework) { $arguments += @(Get-AmithTestArguments $Framework) }
    Invoke-AmithNative dotnet $arguments $Plan.Root
}

function Invoke-AmithRestore {
    param($Plan)
    foreach ($project in @(Get-AmithBuildRoots $Plan)) {
        if ($project.Kind -eq 'Test') {
            foreach ($framework in $project.TestFrameworks) { Invoke-AmithProjectRestore $Plan $project $framework }
        } else {
            Invoke-AmithProjectRestore $Plan $project
        }
    }
}

function Invoke-AmithCompile {
    param($Plan)
    Assert-AmithStage $Plan Restore
    foreach ($project in @(Get-AmithBuildRoots $Plan)) {
        # Another root (or framework) may have restored a shared dependency with
        # different global properties into the same assets file. Let MSBuild
        # check restore immediately before building this graph.
        if ($project.Kind -eq 'Test') {
            foreach ($framework in $project.TestFrameworks) {
                Invoke-AmithNative dotnet (@('build', $project.Path) + @(Get-AmithProjectBuildArguments $Plan $project) + @(Get-AmithTestArguments $framework)) $Plan.Root
            }
        } else {
            Invoke-AmithNative dotnet (@('build', $project.Path) + @(Get-AmithProjectBuildArguments $Plan $project)) $Plan.Root
        }
    }
}

function Invoke-AmithTests {
    param($Plan)
    Assert-AmithStage $Plan Build
    $policy=Get-AmithTestPolicy $Plan
    $projects=@($Plan.Projects | Where-Object Kind -eq 'Test')
    $Plan.TestResults=@{ExecutedTargets=0;SkippedProjects=@();Disposition='Running'}
    Assert-AmithNoTestsDeclaration $Plan.Projects $policy
    if ($policy.NoTests) {
        $Plan.TestResults.Disposition='NoTests'
        Write-Warning 'NoTests: this plan intentionally contains no test projects.'
        return
    }
    if ($policy.SkipTests) {
        $Plan.TestResults.Disposition='Skipped'
        $Plan.TestResults.SkippedProjects=@($projects | ForEach-Object Name)
        Write-Warning 'SkipTests: test execution is explicitly bypassed for this plan.'
        return
    }
    foreach ($project in $projects) {
        if (@($project.TestFrameworks).Count -eq 0) { $Plan.TestResults.SkippedProjects += $project.Name; Write-Warning "Skipping $($project.Name): its frameworks/platform policy are incompatible with this host."; continue }
        foreach ($framework in $project.TestFrameworks) {
            # MTP is selected by the consuming repository's global.json. Traditional
            # VSTest projects use the positional project argument instead.
            $testRunner = 'VSTest'
            $directory = Split-Path -Parent $project.Path
            while ($directory) {
                $globalPath = Join-Path $directory 'global.json'
                if (Test-Path -LiteralPath $globalPath) {
                    $globalConfig = Get-Content -LiteralPath $globalPath -Raw | ConvertFrom-Json -AsHashtable
                    $testRunner = [string](Get-AmithValue (Get-AmithValue $globalConfig 'test' @{}) 'runner' 'VSTest')
                    break
                }
                $parent = Split-Path -Parent $directory
                if ($parent -eq $directory) { break }; $directory = $parent
            }
            # Rehydrate assets for this framework without rebuilding its binaries.
            Invoke-AmithProjectRestore $Plan $project $framework
            $arguments = @('test')
            if ($testRunner -eq 'Microsoft.Testing.Platform') { $arguments += '--project' }
            $arguments += @($project.Path, '--framework', $framework, '--no-build') + @(Get-AmithBuildArguments $Plan) + @(Get-AmithTestArguments $framework)
            Invoke-AmithNative dotnet $arguments $Plan.Root
            $Plan.TestResults.ExecutedTargets++
        }
    }
    if ($Plan.TestResults.ExecutedTargets -eq 0) {
        if (-not $projects.Count) { throw 'No test projects were found. Declare NoTests for an intentionally test-free plan, or explicitly use SkipTests to bypass execution.' }
        throw 'No test targets can run on this host. Check target frameworks and TestPlatforms, use a compatible runner, or explicitly use SkipTests. NoTests is only valid when no test projects are selected.'
    }
    $Plan.TestResults.Disposition='Executed'
}

function Invoke-AmithPack {
    param($Plan)
    Assert-AmithStage $Plan Build
    foreach ($project in @($Plan.Projects | Where-Object { $_.Kind -eq 'Library' -and $_.Pack })) {
        $directory = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "packages/$($project.Name)")
        [void][IO.Directory]::CreateDirectory($directory)
        # Tests may have restored only one of this library's frameworks.
        Invoke-AmithProjectRestore $Plan $project
        Invoke-AmithNative dotnet (@('pack', $project.Path, '--no-build', '--output', $directory, "-p:PackageVersion=$($Plan.Version)") + @(Get-AmithProjectBuildArguments $Plan $project)) $Plan.Root
        $package = Join-Path $directory "$($project.PackageId).$($Plan.Version).nupkg"
        Add-AmithArtifact $Plan NuGet $project $package
        $symbols = Join-Path $directory "$($project.PackageId).$($Plan.Version).snupkg"
        if (Test-Path -LiteralPath $symbols) { Add-AmithArtifact $Plan Symbols $project $symbols }
    }
}

function Invoke-AmithPublish {
    param($Plan)
    Assert-AmithStage $Plan Build
    foreach ($project in @($Plan.Projects | Where-Object { $_.Kind -in @('Desktop', 'Web', 'Console') -and $_.Publish })) {
        foreach ($target in $project.Targets) {
            $directory = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "publish/$($project.Name)/$($target.Runtime)")
            if ((Test-Path -LiteralPath $directory) -and @(Get-ChildItem -LiteralPath $directory -Force).Count) {
                throw 'Publish output is not empty; create a new plan instead of mixing build outputs.'
            }
            # A portable library reference can strip RuntimeIdentifier before an
            # executable dependency is evaluated. RuntimeIdentifiers keeps the
            # whole graph RID-aware, matching restore and build for this target.
            $arguments = @('publish', $project.Path, '--runtime', $target.Runtime, "-p:RuntimeIdentifiers=$($target.Runtime)", '--framework', $target.Framework,
                '--self-contained', ([string][bool]$project.SelfContained).ToLowerInvariant(),
                "-p:PublishSingleFile=$(([string][bool]$project.SingleFile).ToLowerInvariant())",
                "-p:IncludeAllContentForSelfExtract=$(([string][bool]$project.SelfExtract).ToLowerInvariant())", '--output', $directory,
                "-p:CustomAfterMicrosoftCommonTargets=$(Join-Path $PSScriptRoot 'Amith.Build.Publish.targets')",
                "-p:AmithIncludeDevelopmentSettings=$(([string][bool](ConvertTo-AmithBoolean (Get-AmithValue $project 'IncludeDevelopmentSettings' $false))).ToLowerInvariant())")
            $originalHook = [string](Get-AmithValue $project 'OriginalPublishHook' '')
            if ($originalHook) { $arguments += "-p:AmithOriginalCustomAfterMicrosoftCommonTargets=$originalHook" }
            foreach ($argument in $project.PublishArguments) {
                if ($argument -match '^(--output|-o|--runtime|-r|--configuration|-c)(=|$)' -or $argument -match '^[-/]p:(Version|RuntimeIdentifier|RuntimeIdentifiers|PublishDir|PackageVersion|CustomAfterMicrosoftCommonTargets|AmithOriginalCustomAfterMicrosoftCommonTargets|AmithIncludeDevelopmentSettings)=') {
                    throw 'PublishArguments cannot override the plan output, runtime, configuration or version.'
                }
            }
            Invoke-AmithNative dotnet ($arguments + @(Get-AmithBuildArguments $Plan) + @($project.PublishArguments)) $Plan.Root
            Add-AmithArtifact $Plan PublishDirectory $project $directory $target.Runtime
        }
    }
}

function Invoke-AmithArchive {
    param($Plan)
    Assert-AmithStage $Plan Publish
    foreach ($artifact in @($Plan.Artifacts | Where-Object Kind -eq 'PublishDirectory')) {
        $project = @($Plan.Projects | Where-Object Name -eq $artifact.Project)[0]
        if (-not $project.Archive) { continue }
        $packageInput = Get-AmithPackageInput $Plan $project $artifact
        $formats = @($project.ArchiveFormats)
        if ($formats.Count -eq 0) { $formats = if ($artifact.Runtime -like 'linux-*') { @('zip', 'tar.gz') } else { @('zip') } }
        foreach ($format in $formats) {
            if ($format -notin @('zip', 'tar.gz')) { throw "Unsupported archive format: $format" }
            $directory = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot 'archives')
            [void][IO.Directory]::CreateDirectory($directory)
            # Existing saved plans without this setting retain their original
            # versioned names; newly created plans explicitly default to false.
            $versioned = ConvertTo-AmithBoolean (Get-AmithValue $project 'VersionedArchives' $true)
            $versionSuffix = if ($versioned) { "-$($Plan.Version)" } else { '' }
            $destination = Join-Path $directory "$($project.Name)-$($artifact.Runtime)$versionSuffix.$format"
            if (Test-Path -LiteralPath $destination) { throw 'Archive already exists; create a new plan to produce fresh artifacts.' }
            if ($format -eq 'zip') {
                [IO.Compression.ZipFile]::CreateFromDirectory($packageInput.Directory, $destination)
            } else {
                Invoke-AmithNative tar @('-C', $packageInput.Directory, '-czf', $destination, '.') $Plan.Root
            }
            Add-AmithArtifact $Plan Archive $project $destination $artifact.Runtime
        }
    }
}

function Get-AmithEnvironmentSecret {
    param([string] $Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Required environment variable $Name is missing." }
    return $value
}

function Get-AmithVelopackTool {
    param($Plan, $Project)
    $version = [string](Get-AmithValue $Project.Velopack 'ToolVersion' '')
    if (-not $version -and $Project.ProjectAssetsFile -and (Test-Path -LiteralPath $Project.ProjectAssetsFile)) {
        $assets = Get-Content -LiteralPath $Project.ProjectAssetsFile -Raw | ConvertFrom-Json -AsHashtable -Depth 80
        $versions = @((Get-AmithValue $assets 'libraries' @{}).Keys | Where-Object { $_ -like 'Velopack/*' } | ForEach-Object { ($_ -split '/', 2)[1] } | Select-Object -Unique)
        if ($versions.Count -gt 1) { throw 'Multiple restored Velopack versions were found; specify Velopack.ToolVersion.' }
        if ($versions.Count -eq 1) { $version = $versions[0] }
    }
    if ($version) {
        Assert-AmithVersion $version
        return Install-AmithCachedVelopack $version $Plan
    }
    $installed = Get-Command vpk -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($installed) { return $installed.Source }
    $globalTool = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) $(if ($IsWindows) { '.dotnet/tools/vpk.exe' } else { '.dotnet/tools/vpk' })
    if (Test-Path -LiteralPath $globalTool -PathType Leaf) { return $globalTool }
    throw 'Set Velopack.ToolVersion, restore a Velopack application dependency, or install vpk before Installer.'
}

function Invoke-AmithInstaller {
    param($Plan)
    Assert-AmithStage $Plan Publish
    $Plan.Artifacts = @($Plan.Artifacts | Where-Object Kind -ne 'Installer')
    $Plan.VelopackPackages = @()
    [void]$Plan.Stages.Remove('Release')
    $targets = @()
    foreach ($project in $Plan.Projects) {
        $options = $project.Velopack
        if (-not (ConvertTo-AmithBoolean (Get-AmithValue $options 'Enabled' $false))) { continue }
        foreach ($artifact in @($Plan.Artifacts | Where-Object { $_.Kind -eq 'PublishDirectory' -and $_.Project -eq $project.Name })) {
            $channel = Get-AmithVelopackChannel $options $artifact.Runtime
            $targets += @{Project=$project;Options=$options;Artifact=$artifact;Channel=$channel}
        }
    }
    if (@($targets | Group-Object Channel | Where-Object Count -gt 1).Count) { throw 'Velopack targets need distinct channels within one release. Configure Channels by runtime and use different channels per application.' }
    $releaseOptions = Get-AmithValue $Plan.Release 'GitHub' @{}
    $releaseRepository = ''
    if ($targets.Count -and (ConvertTo-AmithBoolean (Get-AmithValue $releaseOptions 'Enabled' $false))) { $releaseRepository = Resolve-AmithVelopackRepository $Plan @{} }
    foreach ($target in $targets) {
        $options = $target.Options
        $repository = [string](Get-AmithValue $options 'Repository' '')
        if (ConvertTo-AmithBoolean (Get-AmithValue $options 'DownloadPrevious' $true)) { $repository = Resolve-AmithVelopackRepository $Plan $options }
        if ($releaseRepository -and $repository -and $repository -ine $releaseRepository) { throw 'Previous-download and release repositories differ. Resolve this before downloading or retaining installer files.' }
        $target.Repository = $repository
    }
    foreach ($target in $targets) {
        $project=$target.Project; $options=$target.Options; $artifact=$target.Artifact; $channel=$target.Channel
        $extra = @(Get-AmithVelopackPackArguments $options (ConvertTo-AmithBoolean (Get-AmithValue $project 'IncludeDevelopmentSettings' $false)))
        $tool = Get-AmithVelopackTool $Plan $project
        $os = if ($artifact.Runtime -like 'win-*') { 'win' } else { 'linux' }
        $attempt = [guid]::NewGuid().ToString('N')
        $directory = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "installers/$($project.Name)/$($artifact.Runtime)/$attempt")
        [void][IO.Directory]::CreateDirectory($directory)
        $packId = [string](Get-AmithValue $options 'PackId' $project.Name)
        $repository = $target.Repository
        $tokenEnvironment = [string](Get-AmithValue $options 'TokenEnvironment' 'GH_TOKEN')
        if (ConvertTo-AmithBoolean (Get-AmithValue $options 'DownloadPrevious' $true)) {
            # Public repositories allow anonymous downloads; private-repository
            # authentication errors still come back from vpk and stop the stage.
            $token = [Environment]::GetEnvironmentVariable($tokenEnvironment)
            $seed = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "previous/$($project.Name)/$($artifact.Runtime)/$attempt")
            [void][IO.Directory]::CreateDirectory($seed)
            $download = @('--yes', '--skip-updates', 'download', 'github', '--repoUrl', "https://github.com/$repository", '--channel', $channel, '--outputDir', $seed)
            if ($token) { $download += @('--token', $token) }
            if (ConvertTo-AmithBoolean (Get-AmithValue $options 'IncludePrereleases' $Plan.Version.Contains('-'))) { $download += '--pre' }
            Invoke-AmithNative $tool $download $Plan.Root -SensitiveValues @($token)
            if (@(Get-ChildItem -LiteralPath $seed -File -Filter '*.incomplete').Count) { throw 'Previous Velopack download did not complete or failed checksum verification.' }
            foreach ($file in @(Get-ChildItem -LiteralPath $seed -File -Filter '*.nupkg')) {
                Assert-AmithPreviousPackage $file.FullName $packId
                Copy-Item -LiteralPath $file.FullName -Destination $directory
            }
            # An empty successful download is a valid first release/channel.
        }
        $packageInput = Get-AmithPackageInput $Plan $project $artifact
        $mainExe = [string](Get-AmithValue $options 'MainExe' $(if ($os -eq 'win') { "$($project.AssemblyName).exe" } else { $project.AssemblyName }))
        $arguments = @("[$os]", '--yes', '--skip-updates', 'pack', '--runtime', $artifact.Runtime, '--packId', $packId,
            '--packVersion', $Plan.Version, '--packDir', $packageInput.Directory, '--mainExe', $mainExe, '--outputDir', $directory, '--channel', $channel)
        $authors = [string](Get-AmithValue $options 'Authors' '')
        if ($authors) { $arguments += @('--packAuthors', $authors) }
        Invoke-AmithNative $tool ($arguments + $extra) $Plan.Root
        $files = @(Get-AmithVelopackBuildFiles $directory $channel)
        foreach ($file in $files) { Add-AmithArtifact $Plan Installer $project $file.Path $artifact.Runtime }
        $manifest = Join-Path $directory "assets.$channel.json"
        Add-AmithArtifact $Plan Installer $project $manifest $artifact.Runtime
        $fingerprintText = ConvertTo-Json -InputObject @($files | Sort-Object Name | ForEach-Object { @($_.Name,$_.SHA256) }) -Compress -Depth 5
        $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprintText + (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash)))
        $Plan.VelopackPackages += @{Project=$project.Name;Runtime=$artifact.Runtime;Os=$os;Channel=$channel;Directory=$directory;Tool=$tool;Repository=$repository;
            TokenEnvironment=$tokenEnvironment;Files=$files;Fingerprint=$fingerprint}
    }
}
