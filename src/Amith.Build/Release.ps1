function Assert-AmithReleaseArtifacts {
    param($Plan)
    if (-not $Plan.ExplicitVersion) { throw 'Release requires an explicitly supplied Version; local default versions cannot be published.' }
    Assert-AmithStage $Plan Build
    Assert-AmithStage $Plan Test
    foreach ($artifact in $Plan.Artifacts) {
        $producer = switch ($artifact.Kind) {
            NuGet { 'Pack' }; Symbols { 'Pack' }; PublishDirectory { 'Publish' }; Archive { 'Archive' }; Installer { 'Installer' }
            default { throw 'Unknown artifact kind in the manifest.' }
        }
        Assert-AmithStage $Plan $producer
        [void](Assert-AmithOutputPath $Plan $artifact.Path)
        if ($artifact.SHA256) {
            if (-not (Test-Path -LiteralPath $artifact.Path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash -ne $artifact.SHA256) {
                throw 'An artifact is missing or changed since packaging. Regenerate the plan and artifacts.'
            }
        }
    }
    Assert-AmithReleaseTestPolicy $Plan
}

function Invoke-AmithNuGetRelease {
    param($Plan, $Options)
    $packages = @($Plan.Artifacts | Where-Object Kind -eq 'NuGet')
    if ($packages.Count -eq 0) { throw 'NuGet release was enabled but this plan has no packaged NuGet artifacts.' }
    Assert-AmithStage $Plan Pack
    $source = Get-AmithEnvironmentSecret ([string](Get-AmithValue $Options 'SourceEnvironment' 'NUGET_SOURCE_URL'))
    $key = Get-AmithEnvironmentSecret ([string](Get-AmithValue $Options 'ApiKeyEnvironment' 'NUGET_API_KEY'))
    $uri = $null
    if (-not [Uri]::TryCreate($source, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https', 'http')) { throw 'The NuGet source environment variable must contain an absolute feed URL.' }
    if (-not $Plan.Contains('NuGetPublished')) { $Plan.NuGetPublished = @() }
    foreach ($package in $packages) {
        if (@($Plan.NuGetPublished | Where-Object { $_.SHA256 -eq $package.SHA256 -and $_.Path -eq $package.Path }).Count) { continue }
        Invoke-AmithNative dotnet @('nuget', 'push', $package.Path, '--source', $source, '--api-key', $key, '--no-symbols', '--timeout', '300') $Plan.Root -SensitiveValues @($key, $source, $uri.GetLeftPart([UriPartial]::Authority))
        $Plan.NuGetPublished += @{ Path = $package.Path; SHA256 = $package.SHA256 }
        Write-AmithJson $Plan $Plan.PlanPath
    }
}

function Invoke-AmithGitHubRelease {
    param($Plan, $Options)
    $repo = [string](Get-AmithValue $Options 'Repository' $env:GITHUB_REPOSITORY)
    if (-not $repo) {
        $remote = (@(Invoke-AmithNative git @('remote', 'get-url', 'origin') $Plan.Root -Capture) -join '').Trim()
        if ($remote -notmatch '[:/]([^/:]+)/([^/]+?)(?:\.git)?$') { throw 'Supply Release.GitHub.Repository as owner/repo.' }
        $repo = "$($Matches[1])/$($Matches[2])"
    }
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'GitHub Repository must be owner/repo.' }
    $commit = (@(Invoke-AmithNative git @('rev-parse', 'HEAD') $Plan.Root -Capture) -join '').Trim()
    if (-not $Plan.SourceCommit -or $commit -ne $Plan.SourceCommit) { throw 'The source commit changed or was unavailable when planned. Regenerate the build plan and artifacts before releasing.' }
    if (ConvertTo-AmithBoolean (Get-AmithValue $Options 'RequireCleanTree' $true)) {
        $dirty = @(Invoke-AmithNative git @('status', '--porcelain', '--untracked-files=normal') $Plan.Root -Capture)
        # Our own plan/output files must not make a clean checkout look dirty.
        $generated = @()
        foreach ($directory in @($Plan.OutputBase, (Split-Path -Parent $Plan.PlanPath))) {
            $relative = [IO.Path]::GetRelativePath($Plan.Root, $directory).Replace('\', '/').TrimEnd('/')
            if ($relative -ne '.' -and $relative -notlike '../*') { $generated += $relative }
        }
        $dirtySource = @($dirty | Where-Object {
            $path = $_.Substring(3).Trim('"').Replace('\', '/').TrimEnd('/')
            @($generated | Where-Object { $path -eq $_ -or $path.StartsWith($_ + '/', [StringComparison]::Ordinal) }).Count -eq 0
        })
        if ($dirtySource.Count) { throw 'GitHub releases require a clean committed source tree (or an explicit RequireCleanTree override).' }
    }
    $assets = @($Plan.Artifacts | Where-Object Kind -in @('Archive', 'NuGet', 'Symbols'))
    $packages = @(Get-AmithValue $Plan 'VelopackPackages' @())
    if (@($Plan.Artifacts | Where-Object Kind -eq 'Installer').Count -and -not $packages.Count) {
        throw 'Installer artifacts have no Velopack upload manifest. Rerun Installer before releasing.'
    }
    if (-not $assets.Count -and -not $packages.Count) { throw 'No packaged files are available for a GitHub release.' }
    $names = @($assets | ForEach-Object { [IO.Path]::GetFileName($_.Path) })
    foreach ($package in $packages) {
        if ($package.Repository -and $package.Repository -ine $repo) { throw 'Previous-download and release repositories differ. Regenerate installer artifacts for this repository.' }
        if (-not (Test-Path -LiteralPath $package.Tool -PathType Leaf)) { throw 'The planned Velopack tool is missing. Rerun Installer on this host.' }
        $names += @(Get-AmithVelopackUploadNames $package)
    }
    if (@($names | Group-Object | Where-Object Count -gt 1).Count) {
        throw 'GitHub assets or Velopack channel feed filenames collide. Use distinct package names/channels per target.'
    }
    $duplicates = @($assets | Group-Object { [IO.Path]::GetFileName($_.Path) } | Where-Object Count -gt 1)
    if ($duplicates.Count) { throw 'GitHub release assets need unique filenames; split per-project/channel releases or use unique artifact names.' }
    $tag = [string](Get-AmithValue $Options 'TagPrefix' 'v') + $Plan.Version
    $releases = ((@(Invoke-AmithNative gh @('release', 'list', '--repo', $repo, '--limit', '100', '--json', 'tagName,isDraft') $Plan.Root -Capture) -join "`n") | ConvertFrom-Json -AsHashtable)
    $existing = @($releases | Where-Object tagName -eq $tag)
    if ($existing.Count -and -not $existing[0].isDraft) { throw 'This version already has a published GitHub release.' }
    if ($existing.Count -eq 0) {
        $arguments = @('release', 'create', $tag, '--repo', $repo, '--target', $commit, '--title', $tag, '--draft', '--generate-notes')
        if ($Plan.Version.Contains('-')) { $arguments += '--prerelease' }
        Invoke-AmithNative gh $arguments $Plan.Root
    }
    if ($assets.Count) {
        Invoke-AmithNative gh (@('release', 'upload', $tag, '--repo', $repo, '--clobber') + @($assets | ForEach-Object Path)) $Plan.Root
    }
    foreach ($package in $packages) { Invoke-AmithVelopackUpload $Plan $package $repo $tag $commit }
    # Recheck every completed channel immediately before final publication.
    foreach ($package in $packages) {
        $release = Get-AmithGitHubDraft $Plan $repo $tag
        $receipt = $Plan.VelopackUploads["$repo|$tag|$($package.Channel)"]
        foreach ($asset in $receipt.Assets) {
            if (@($release.assets | Where-Object { $_.name -ceq $asset.name -and $_.id -eq $asset.id -and $_.size -eq $asset.size -and (Get-AmithValue $_ 'digest' '') -eq (Get-AmithValue $asset 'digest' '') }).Count -ne 1) {
                throw 'Velopack assets changed before publication; release remains draft.'
            }
        }
    }
    if (-not (ConvertTo-AmithBoolean (Get-AmithValue $Options 'Draft' $false))) {
        Invoke-AmithNative gh @('release', 'edit', $tag, '--repo', $repo, '--draft=false') $Plan.Root
    }
}

function Invoke-AmithRelease {
    param($Plan)
    Assert-AmithReleaseArtifacts $Plan
    $nuget = Get-AmithValue $Plan.Release 'NuGet' @{}
    $github = Get-AmithValue $Plan.Release 'GitHub' @{}
    $useNuGet = ConvertTo-AmithBoolean (Get-AmithValue $nuget 'Enabled' $false)
    $useGitHub = ConvertTo-AmithBoolean (Get-AmithValue $github 'Enabled' $false)
    if (-not $useNuGet -and -not $useGitHub) { throw 'Enable Release.NuGet or Release.GitHub in the configuration before invoking Release.' }
    if ($useNuGet) { Invoke-AmithNuGetRelease $Plan $nuget }
    if ($useGitHub) { Invoke-AmithGitHubRelease $Plan $github }
}
