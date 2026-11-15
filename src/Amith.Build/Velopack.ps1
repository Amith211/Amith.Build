function Get-AmithVelopackChannel {
    param($Options, [string] $Runtime)
    $os = if ($Runtime -like 'win-*') { 'win' } elseif ($Runtime -like 'linux-*') { 'linux' } else { throw 'Velopack supports win-* and linux-* targets.' }
    $channel = [string](Get-AmithValue (Get-AmithValue $Options 'Channels' @{}) $Runtime (Get-AmithValue $Options 'Channel' $os))
    if ($channel -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw 'Velopack channels must contain lowercase letters, digits, dots, underscores or hyphens.' }
    return $channel
}

function Get-AmithVelopackPackArguments {
    param($Options, [bool] $IncludeDevelopmentSettings = $false)
    $patterns = @('.*\.pdb', '(^|[\\/])([^\\/]*\.Development\.json|Development\.json|splash-image\.(jpg|jpeg|png|svg))$')
    if ($IncludeDevelopmentSettings) { $patterns = @('.*\.pdb', '(^|[\\/])splash-image\.(jpg|jpeg|png|svg)$') }
    $patterns += @(Get-AmithValue $Options 'Excludes' @())
    $extra = @(Get-AmithValue $Options 'PackArguments' @())
    $remaining = @()
    for ($i = 0; $i -lt $extra.Count; $i++) {
        $argument = [string]$extra[$i]
        if ($argument -eq '--exclude') {
            if (++$i -ge $extra.Count) { throw 'PackArguments --exclude requires a regex.' }
            $patterns += [string]$extra[$i]
        } elseif ($argument -like '--exclude=*') {
            $patterns += $argument.Substring('--exclude='.Length)
        } elseif ($argument -match '^(--(packId|packVersion|packDir|outputDir|channel|runtime|mainExe|noDefaultExclude)|-[uvpocre])(=|$)') {
            throw "PackArguments cannot override planned packaging options or disable default exclusions: $argument"
        } else { $remaining += $argument }
    }
    foreach ($pattern in $patterns) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { throw 'Velopack exclusion patterns cannot be empty.' }
        try { [void][regex]::new([string]$pattern) } catch { throw "Invalid Velopack exclusion regex: $pattern" }
    }
    $combined = (@($patterns | ForEach-Object { '(?:' + $_ + ')' }) -join '|')
    return @('--exclude', $combined) + $remaining
}

function Resolve-AmithVelopackRepository {
    param($Plan, $Options)
    $repo = [string](Get-AmithValue $Options 'Repository' (Get-AmithValue (Get-AmithValue $Plan.Release 'GitHub' @{}) 'Repository' $env:GITHUB_REPOSITORY))
    if (-not $repo) {
        $remote = (@(Invoke-AmithNative git @('remote','get-url','origin') $Plan.Root -Capture) -join '').Trim()
        if ($remote -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?$') { $repo = "$($Matches[1])/$($Matches[2])" }
    }
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Velopack requires Repository (owner/repo), Release.GitHub.Repository, or a GitHub origin remote.' }
    return $repo
}

function Assert-AmithPreviousPackage {
    param([string] $Path, [string] $PackId)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $nuspecs = @($archive.Entries | Where-Object { $_.FullName -notmatch '[/\\]' -and $_.FullName.EndsWith('.nuspec') })
        if ($nuspecs.Count -ne 1) { throw 'Previous Velopack package must contain exactly one root nuspec.' }
        $stream = $nuspecs[0].Open()
        try {
            $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null; $settings.MaxCharactersInDocument = 1048576
            $reader = [Xml.XmlReader]::Create($stream, $settings)
            try {
                $document = [Xml.XmlDocument]::new(); $document.XmlResolver = $null; $document.Load($reader)
                $id = $document.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]/*[local-name()="id"]')
                if ($null -eq $id -or $id.InnerText -ine $PackId) { throw 'Previous package belongs to a different application; use distinct Velopack channels per application.' }
            } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
}

function Get-AmithVelopackBuildFiles {
    param([string] $Directory, [string] $Channel)
    $manifest = Join-Path $Directory "assets.$Channel.json"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Velopack did not create build manifest assets.$Channel.json." }
    $entries = @(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable)
    if (-not $entries.Count) { throw 'Velopack build manifest has no generated assets.' }
    $files = @()
    foreach ($entry in $entries) {
        $name = [string](Get-AmithValue $entry 'RelativeFileName' '')
        if (-not $name -or [IO.Path]::IsPathFullyQualified($name)) { throw 'Invalid path in Velopack build manifest.' }
        $path = Assert-AmithOutputPath @{OutputRoot=$Directory} (Resolve-AmithPath $name $Directory)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Velopack build asset: $name" }
        $files += @{ Name=[IO.Path]::GetFileName($path); Path=$path; SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; Size=(Get-Item -LiteralPath $path).Length }
    }
    if (@($files | Group-Object Name | Where-Object Count -gt 1).Count) { throw 'Velopack build assets have duplicate filenames.' }
    return $files
}

function Get-AmithVelopackUploadNames {
    param($Package)
    $names = @($Package.Files | ForEach-Object Name) + @("releases.$($Package.Channel).json")
    if ($Package.Channel -ceq 'win') { $names += 'RELEASES' }
    return $names
}

function Get-AmithGitHubDraft {
    param($Plan, [string] $Repository, [string] $Tag)
    # Drafts can be absent from REST's by-tag endpoint. Resolve through gh's
    # draft-aware lookup, then read raw asset IDs/digests from the release-ID API.
    $lookupJson = @(Invoke-AmithNative gh @('release', 'view', $Tag, '--repo', $Repository, '--json', 'apiUrl') $Plan.Root -Capture) -join "`n"
    $lookup = $lookupJson | ConvertFrom-Json -AsHashtable
    if (-not $lookup.apiUrl -or $lookup.apiUrl -notmatch ('/repos/' + [regex]::Escape($Repository) + '/releases/[0-9]+$')) {
        throw 'GitHub draft lookup did not return the expected repository release API URL.'
    }
    $json = @(Invoke-AmithNative gh @('api', [string]$lookup.apiUrl) $Plan.Root -Capture) -join "`n"
    $release = $json | ConvertFrom-Json -AsHashtable
    if (-not $release.draft -or $release.tag_name -cne $Tag) { throw 'Velopack uploads require the expected GitHub draft release.' }
    return $release
}

function Invoke-AmithVelopackUpload {
    param($Plan, $Package, [string] $Repository, [string] $Tag, [string] $Commit)
    $release = Get-AmithGitHubDraft $Plan $Repository $Tag
    if (-not $Plan.Contains('VelopackUploads')) { $Plan.VelopackUploads = @{} }
    $key = "$Repository|$Tag|$($Package.Channel)"
    $previous = Get-AmithValue $Plan.VelopackUploads $key @{}
    $expected = @(Get-AmithVelopackUploadNames $Package)
    $remote = @($release.assets | Where-Object { $_.name -in $expected })
    if ((Get-AmithValue $previous 'Status' '') -eq 'Succeeded') {
        if ($previous.Fingerprint -ne $Package.Fingerprint) { throw 'Velopack artifacts changed after upload. Use a new plan/version.' }
        foreach ($asset in $previous.Assets) {
            $matching = @($remote | Where-Object { $_.name -ceq $asset.name -and $_.id -eq $asset.id -and $_.size -eq $asset.size -and (Get-AmithValue $_ 'digest' '') -eq (Get-AmithValue $asset 'digest' '') })
            if ($matching.Count -ne 1) { throw 'Previously uploaded Velopack assets changed or are missing from the draft.' }
        }
        Write-Host "Velopack channel $($Package.Channel) already uploaded and verified; skipping."
        return
    }
    if ($remote.Count) {
        throw "Partial or conflicting Velopack upload for channel '$($Package.Channel)'. The release remains draft. Remove only this channel's partial/conflicting assets from the draft before retrying; --merge cannot overwrite an existing feed."
    }
    $token = Get-AmithEnvironmentSecret $Package.TokenEnvironment
    $Plan.VelopackUploads[$key] = @{Status='Running';Fingerprint=$Package.Fingerprint;Names=$expected}
    Write-AmithJson $Plan $Plan.PlanPath
    $arguments = @("[$($Package.Os)]", '--yes', '--skip-updates', 'upload', 'github', '--merge',
        '--channel', $Package.Channel, '--repoUrl', "https://github.com/$Repository", '--releaseName', $Tag,
        '--tag', $Tag, '--targetCommitish', $Commit, '--outputDir', $Package.Directory, '--token', $token)
    if ($Plan.Version.Contains('-')) { $arguments += '--pre' }
    # No --publish: the orchestrator promotes the draft after every target succeeds.
    Invoke-AmithNative $Package.Tool $arguments $Plan.Root -SensitiveValues @($token)
    $release = Get-AmithGitHubDraft $Plan $Repository $Tag
    $uploaded = @()
    foreach ($name in $expected) {
        $assets = @($release.assets | Where-Object { $_.name -ceq $name })
        if ($assets.Count -ne 1) { throw "Velopack upload did not produce expected remote asset '$name'. Release remains draft." }
        $local = @($Package.Files | Where-Object Name -ceq $name)
        if ($local.Count) {
            $digest = [string](Get-AmithValue $assets[0] 'digest' '')
            if ($assets[0].size -ne $local[0].Size -or ($digest -and $digest -ine "sha256:$($local[0].SHA256)")) {
                throw "Velopack remote asset '$name' differs from the packaged file. Release remains draft."
            }
        }
        $uploaded += $assets[0]
    }
    $Plan.VelopackUploads[$key] = @{Status='Succeeded';Fingerprint=$Package.Fingerprint;Assets=$uploaded}
    Write-AmithJson $Plan $Plan.PlanPath
}
