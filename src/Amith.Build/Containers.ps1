# Container configuration contains references to secrets, never their values.
function Get-AmithContainerPlans {
    param($Config, [string] $Root, [string] $Version)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $destinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $registry = ''
    foreach ($entry in @(Get-AmithValue $Config 'Containers' @())) {
        if ($entry -isnot [Collections.IDictionary]) { throw 'Each Containers entry must be a map.' }
        foreach ($key in $entry.Keys) {
            if ($key -notin @('Name','Context','Dockerfile','Target','Image','Platforms','Tag','BuildArguments','Secrets','TestSuites')) { throw "Unknown container setting: $key" }
        }
        $name = [string](Get-AmithValue $entry 'Name' '')
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or -not $names.Add($name)) { throw 'Container names must be unique simple artifact names.' }
        $image = [string](Get-AmithValue $entry 'Image' '')
        if ($image -cnotmatch '^(?<registry>[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]+)?)/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$') {
            throw 'Container Image must be a lowercase registry/repository without a scheme, tag or digest.'
        }
        $hostName = $Matches.registry
        if ($registry -and $registry -cne $hostName) { throw 'All containers in a plan must use the same registry.' }
        $registry = $hostName
        $tag = [string](Get-AmithValue $entry 'Tag' $Version)
        if ($tag -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' -or $tag -ceq 'latest') { throw 'Container Tag must be a valid version tag other than latest.' }
        if (-not $destinations.Add($image)) { throw 'Each container must have a unique image repository.' }
        $context = Resolve-AmithContainerPath $Root ([string](Get-AmithValue $entry 'Context' '.')) -Directory
        $dockerfile = Resolve-AmithContainerPath $Root ([string](Get-AmithValue $entry 'Dockerfile' 'Dockerfile'))
        if ($dockerfile.Contains(',')) { throw 'Container Dockerfile paths cannot contain commas.' }
        $target = [string](Get-AmithValue $entry 'Target' '')
        if ($target -and $target -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { throw 'Invalid Dockerfile target.' }
        $platforms = @(Get-AmithValue $entry 'Platforms' @('linux/amd64'))
        if (-not $platforms.Count -or @($platforms | Where-Object { $_ -cnotmatch '^linux/(amd64|arm64|arm/v[5-8]|386|ppc64le|s390x|riscv64)$' }).Count -or @($platforms | Select-Object -Unique).Count -ne $platforms.Count) {
            throw 'Containers require unique Linux platforms such as linux/amd64 or linux/arm64.'
        }
        $arguments = Get-AmithValue $entry 'BuildArguments' @{}
        if ($arguments -isnot [Collections.IDictionary]) { throw 'Container BuildArguments must be a map.' }
        foreach ($key in $arguments.Keys) {
            if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $key -like 'AMITH_*' -or $arguments[$key] -isnot [string] -or $arguments[$key].Contains([char]0)) {
                throw 'BuildArguments require string values and simple names; AMITH_* names are reserved.'
            }
        }
        $secrets = @(); $secretIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($secret in @(Get-AmithValue $entry 'Secrets' @())) {
            if ($secret -isnot [Collections.IDictionary]) { throw 'Container Secrets entries must be maps.' }
            foreach ($key in $secret.Keys) { if ($key -notin @('Id','Source','Environment')) { throw 'Unknown container secret setting.' } }
            $id = [string](Get-AmithValue $secret 'Id' '')
            $source = [string](Get-AmithValue $secret 'Source' '')
            $variable = [string](Get-AmithValue $secret 'Environment' '')
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or -not $secretIds.Add($id)) { throw 'Container secret IDs must be unique simple names.' }
            if ($source -ceq 'NuGetRestoreSources') {
                if ($variable) { throw 'NuGetRestoreSources secrets do not take Environment.' }
            } elseif ($source -ceq 'Environment') {
                if ($variable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Environment secrets need an environment variable name.' }
            } else { throw 'Container secret Source must be NuGetRestoreSources or Environment.' }
            $secrets += @{Id=$id;Source=$source;Environment=$variable}
        }
        @{
            Name=$name; Context=$context; Dockerfile=$dockerfile; DockerfileSHA256=(Get-FileHash -LiteralPath $dockerfile -Algorithm SHA256).Hash
            Target=$target; Image=$image; Registry=$registry; Tag=$tag; Platforms=$platforms; BuildArguments=$arguments; Secrets=$secrets; TestSuites=@(Get-AmithValue $entry 'TestSuites' @())
        }
    }
}

function Resolve-AmithContainerPath {
    param([string] $Root, [string] $Path, [switch] $Directory)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Container paths cannot be empty.' }
    $full = Resolve-AmithPath $Path $Root
    $relative = [IO.Path]::GetRelativePath($Root,$full)
    if ([IO.Path]::IsPathFullyQualified($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar)) { throw 'Container paths must stay inside the repository root.' }
    $kind = if ($Directory) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $full -PathType $kind)) { throw "Container input does not exist: $full" }
    $current = $full
    while ($true) {
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Container input paths cannot traverse symbolic links or junctions.' }
        if ($current -eq [IO.Path]::GetFullPath($Root)) { break }
        $current = Split-Path -Parent $current
        if (-not $current) { throw 'Container path root could not be verified.' }
    }
    return $full
}

function Assert-AmithContainerReleaseOptions {
    param($Options)
    if ($Options -isnot [Collections.IDictionary]) { throw 'Release.Containers must be a map.' }
    foreach ($key in $Options.Keys) { if ($key -notin @('Enabled','TagAsLatest')) { throw "Unknown Release.Containers setting: $key" } }
    [void](ConvertTo-AmithBoolean (Get-AmithValue $Options 'Enabled' $false))
    [void](ConvertTo-AmithBoolean (Get-AmithValue $Options 'TagAsLatest' $false))
}

function Write-AmithContainerNuGetConfig {
    param([string] $Path)
    Protect-AmithNuGetValue $env:AMITH_NUGET_RESTORE_SOURCES
    $sources = @(Read-AmithNuGetSources $env:AMITH_NUGET_RESTORE_SOURCES)
    if (-not $sources.Count) { throw 'NuGetRestoreSources container secret requires AMITH_NUGET_RESTORE_SOURCES.' }
    $document = [Xml.XmlDocument]::new()
    $root = $document.CreateElement('configuration'); [void]$document.AppendChild($root)
    $feeds = $document.CreateElement('packageSources'); [void]$root.AppendChild($feeds)
    [void]$feeds.AppendChild($document.CreateElement('clear'))
    $credentials = $document.CreateElement('packageSourceCredentials'); [void]$root.AppendChild($credentials)
    foreach ($source in $sources) {
        $uri = $null
        if (-not [Uri]::TryCreate($source.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https')) { throw 'Container NuGet sources must use HTTP(S); runner filesystem feeds are unavailable inside BuildKit.' }
        Set-AmithNuGetSetting $feeds $source.name $source.url
        if ($source.Contains('username')) {
            Protect-AmithNuGetValue $source.username; Protect-AmithNuGetValue $source.password
            $entry = $document.CreateElement([Xml.XmlConvert]::EncodeLocalName($source.name)); [void]$credentials.AppendChild($entry)
            Set-AmithNuGetSetting $entry 'Username' $source.username
            Set-AmithNuGetSetting $entry 'ClearTextPassword' $source.password
            if ($source.Contains('validAuthenticationTypes')) { Set-AmithNuGetSetting $entry 'ValidAuthenticationTypes' $source.validAuthenticationTypes }
        }
    }
    $document.Save($Path)
}

# Read and hash the archive without extracting any untrusted paths. JSON blobs
# are bounded; layer data is streamed through SHA256 rather than buffered.
function Read-AmithOciArchive {
    param([string] $Path, [string[]] $Platforms)
    Add-Type -AssemblyName System.Formats.Tar
    $stream = [IO.File]::OpenRead($Path)
    $reader = [System.Formats.Tar.TarReader]::new($stream,$true)
    $blobs = @{}; $index = $null; $layout = $null
    $entries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            if ($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory) { continue }
            if ($entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile,[System.Formats.Tar.TarEntryType]::V7RegularFile)) { throw 'OCI archive contains a non-regular file.' }
            $name = $entry.Name -replace '^\./',''
            if (-not $entries.Add($name)) { throw 'OCI archive contains duplicate entries.' }
            if ($name -in @('index.json','oci-layout')) {
                if ($entry.Length -gt 16MB) { throw 'OCI metadata exceeds the supported size.' }
                $textReader = [IO.StreamReader]::new($entry.DataStream,[Text.Encoding]::UTF8,$true,4096,$true)
                try { $json = $textReader.ReadToEnd() | ConvertFrom-Json -AsHashtable -Depth 60 } finally { $textReader.Dispose() }
                if ($name -eq 'index.json') { $index = $json } else { $layout = $json }
            } elseif ($name -cmatch '^blobs/sha256/([a-f0-9]{64})$') {
                $digest = 'sha256:'+$Matches[1]
                $bytes = $null
                if ($entry.Length -le 16MB) {
                    $memory = [IO.MemoryStream]::new()
                    try { $entry.DataStream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
                    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
                } else { $hash = [Security.Cryptography.SHA256]::HashData($entry.DataStream) }
                if ('sha256:'+([Convert]::ToHexString($hash).ToLowerInvariant()) -cne $digest) { throw 'OCI blob digest does not match its content.' }
                # Keep JSON only; discard small binary layer data immediately.
                $json = $null
                if ($bytes -and $bytes[0] -eq 123) {
                    try { $json = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 60 } catch { $json = $null }
                }
                $blobs[$digest] = @{Size=$entry.Length;Json=$json}
            } else { throw "Unsupported OCI archive entry: $name" }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
    if (-not $layout -or (Get-AmithValue $layout 'imageLayoutVersion' '') -cne '1.0.0' -or -not $index -or (Get-AmithValue $index 'schemaVersion' 0) -ne 2) { throw 'Invalid OCI archive layout.' }
    $roots = @(Get-AmithValue $index 'manifests' @())
    if ($roots.Count -ne 1) { throw 'OCI archive must contain exactly one root image descriptor.' }
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    function Read-Descriptor($descriptor, [int] $Depth) {
        if ($Depth -gt 16) { throw 'OCI descriptor nesting is too deep.' }
        $digest = [string](Get-AmithValue $descriptor 'digest' '')
        if (-not $blobs.ContainsKey($digest) -or $blobs[$digest].Size -ne (Get-AmithValue $descriptor 'size' -1)) { throw 'OCI descriptor references a missing or incorrectly sized blob.' }
        if (-not $visited.Add($digest)) { return }
        $type = [string](Get-AmithValue $descriptor 'mediaType' '')
        $json = $blobs[$digest].Json
        if ($type -in @('application/vnd.oci.image.index.v1+json','application/vnd.docker.distribution.manifest.list.v2+json')) {
            if (-not $json -or $json.schemaVersion -ne 2) { throw 'Invalid OCI image index.' }
            foreach ($child in $json.manifests) { Read-Descriptor $child ($Depth+1) }
        } elseif ($type -in @('application/vnd.oci.image.manifest.v1+json','application/vnd.docker.distribution.manifest.v2+json')) {
            if (-not $json -or $json.schemaVersion -ne 2) { throw 'Invalid OCI image manifest.' }
            Read-Descriptor $json.config ($Depth+1)
            foreach ($layer in $json.layers) { Read-Descriptor $layer ($Depth+1) }
            $config = $blobs[$json.config.digest].Json
            if (-not $config) { throw 'OCI image configuration is missing or too large.' }
            $os = [string](Get-AmithValue $config 'os' '')
            $architecture = [string](Get-AmithValue $config 'architecture' '')
            if ($os -eq 'linux') {
                $platform = "$os/$architecture"
                $variant = [string](Get-AmithValue $config 'variant' (Get-AmithValue (Get-AmithValue $descriptor 'platform' @{}) 'variant' ''))
                if ($variant -and $architecture -eq 'arm') { $platform += "/$variant" }
                [void]$found.Add($platform)
            }
        }
    }
    Read-Descriptor $roots[0] 0
    $expectedPlatforms = ($Platforms | Sort-Object) -join ','
    $actualPlatforms = (@($found) | Sort-Object) -join ','
    if ($expectedPlatforms -cne $actualPlatforms) { throw 'OCI image platforms do not match the container plan.' }
    return @{Digest=[string]$roots[0].digest;Platforms=@($found | Sort-Object)}
}

function Invoke-AmithContainer {
    param($Plan, [string] $Builder)
    $containers = @(Get-AmithValue $Plan 'Containers' @())
    if (-not $containers.Count) { return }
    Assert-AmithStage $Plan Build; Assert-AmithStage $Plan Test
    Assert-AmithReleaseTestPolicy $Plan
    if (-not $Builder) { $Builder = $env:AMITH_CONTAINER_BUILDER }
    if (-not $Builder) { throw 'Container requires ContainerBuilder or AMITH_CONTAINER_BUILDER naming an existing Buildx builder.' }
    $toolVersion = @(Invoke-AmithNative docker @('buildx','version') -Capture) -join "`n"
    foreach ($container in $containers) {
        [void](Resolve-AmithContainerPath $Plan.Root $container.Context -Directory)
        [void](Resolve-AmithContainerPath $Plan.Root $container.Dockerfile)
        if ((Get-FileHash -LiteralPath $container.Dockerfile -Algorithm SHA256).Hash -cne $container.DockerfileSHA256) { throw 'Dockerfile changed since Plan. Create a fresh plan.' }
        $directory = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "containers/$($container.Name)/$([guid]::NewGuid().ToString('N'))")
        [void][IO.Directory]::CreateDirectory($directory)
        $archive = Join-Path $directory "$($container.Name).oci.tar"
        if ($archive.Contains(',')) { throw 'Container output paths cannot contain commas.' }
        # Secrets live outside both the source context and retained output.
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('amith-container-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($temporary)
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($temporary,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)) }
        try {
            $sensitive = @()
            $arguments = @('buildx','build','--builder',$Builder,'--progress=plain','--file',$container.Dockerfile,'--platform',($container.Platforms -join ','),'--output',"type=oci,dest=$archive",'--tag',"$($container.Image):$($container.Tag)",'--label',"org.opencontainers.image.version=$($Plan.Version)",'--label',"org.opencontainers.image.revision=$($Plan.SourceCommit)",'--build-arg',"AMITH_VERSION=$($Plan.Version)",'--build-arg',"AMITH_SOURCE_COMMIT=$($Plan.SourceCommit)")
            if ($container.Target) { $arguments += @('--target',$container.Target) }
            foreach ($key in @($container.BuildArguments.Keys | Sort-Object)) { $arguments += @('--build-arg',"$key=$($container.BuildArguments[$key])") }
            foreach ($secret in $container.Secrets) {
                if ($secret.Source -ceq 'NuGetRestoreSources') {
                    $file = Join-Path $temporary "$($secret.Id).config"
                    Write-AmithContainerNuGetConfig $file
                    foreach ($source in @(Read-AmithNuGetSources $env:AMITH_NUGET_RESTORE_SOURCES)) {
                        if ($source.Contains('password')) { $sensitive += @($source.username,$source.password) }
                    }
                    $arguments += @('--secret',"id=$($secret.Id),src=$file")
                } else {
                    if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($secret.Environment))) { throw "Required container secret environment variable is missing: $($secret.Environment)" }
                    $sensitive += [Environment]::GetEnvironmentVariable($secret.Environment)
                    $arguments += @('--secret',"id=$($secret.Id),env=$($secret.Environment)")
                }
            }
            $arguments += $container.Context
            Invoke-AmithNative docker $arguments $Plan.Root -SensitiveValues $sensitive
            $image = Read-AmithOciArchive $archive $container.Platforms
            Add-AmithArtifact $Plan ContainerArchive $container $archive
            $artifact = @($Plan.Artifacts | Where-Object Path -eq $archive)[0]
            $artifact.Image=$container.Image; $artifact.Tag=$container.Tag; $artifact.Digest=$image.Digest
            $artifact.Platforms=$image.Platforms; $artifact.SourceCommit=$Plan.SourceCommit
            $artifact.BuildxVersion=$toolVersion; $artifact.DockerfileSHA256=$container.DockerfileSHA256
            Write-Host "Container $($container.Name): $($image.Digest) (OCI archive; runtime execution not tested)"
        } finally {
            # The directory is created here from a GUID under the OS temporary root.
            $verified = [IO.Path]::GetFullPath($temporary)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
            if (-not $verified.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($verified) -notlike 'amith-container-*') { throw 'Container secret cleanup path escaped the temporary root.' }
            Remove-Item -LiteralPath $verified -Recurse -Force
        }
    }
}

function Get-AmithContainerAuthArguments {
    $path = $env:REGISTRY_AUTH_FILE
    if (-not $path -and $env:DOCKER_CONFIG) { $path = Join-Path $env:DOCKER_CONFIG 'config.json' }
    if ($path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Container registry authentication file does not exist.' }
        return @('--authfile',$path)
    }
}

function Invoke-AmithRegistryInspect {
    param([string] $Reference)
    # Preserve raw manifest bytes (no line splitting) for the registry digest.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'skopeo'; $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in (@('inspect','--raw') + @(Get-AmithContainerAuthArguments) + @("docker://$Reference"))) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return @{ExitCode=$process.ExitCode;Output=$output.GetAwaiter().GetResult();Error=$errors.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}

function Get-AmithRegistryDigest {
    param([string] $Reference)
    $result = Invoke-AmithRegistryInspect $Reference
    if ($result.ExitCode -ne 0) {
        # Authentication, TLS and network errors must never mean "absent".
        if ($result.Error -match '(?i)manifest unknown|manifest_unknown|name unknown|name_unknown') { return '' }
        throw 'Could not inspect the registry image. Check authentication, TLS and connectivity.'
    }
    return 'sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($result.Output))).ToLowerInvariant())
}

function Save-AmithContainerPublication {
    param($Plan, [string] $Reference, [string] $Digest)
    $records = @(Get-AmithValue $Plan 'ContainerPublications' @())
    $Plan.ContainerPublications = @($records | Where-Object Reference -cne $Reference) + @(@{Reference=$Reference;Digest=$Digest;PublishedUtc=[DateTime]::UtcNow.ToString('o')})
    Write-AmithJson $Plan $Plan.PlanPath
    Write-Host "Published ${Reference} -> $Digest"
}

function Invoke-AmithContainerRelease {
    param($Plan, $Options)
    Assert-AmithContainerReleaseOptions $Options
    Assert-AmithStage $Plan Container
    $containers = @(Get-AmithValue $Plan 'Containers' @())
    if (-not $containers.Count) { throw 'Container release is enabled but the plan contains no containers.' }
    $artifacts = @($Plan.Artifacts | Where-Object Kind -eq ContainerArchive)
    if ($artifacts.Count -ne $containers.Count) { throw 'Container release requires an archive for every configured image.' }
    $latest = ConvertTo-AmithBoolean (Get-AmithValue $Options 'TagAsLatest' $false)
    $Plan.ContainerReleaseToolVersion = @(Invoke-AmithNative skopeo @('--version') -Capture) -join "`n"
    foreach ($container in $containers) {
        $matches = @($artifacts | Where-Object Project -ceq $container.Name)
        if ($matches.Count -ne 1) { throw 'Container artifact does not match the plan.' }
        $artifact = $matches[0]
        if ($artifact.Image -cne $container.Image -or $artifact.Tag -cne $container.Tag -or $artifact.SourceCommit -cne $Plan.SourceCommit) { throw 'Container artifact identity does not match the plan.' }
        if (-not $artifact.SHA256 -or (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash -cne $artifact.SHA256) { throw 'Container archive is missing or changed since packaging.' }
        $image = Read-AmithOciArchive $artifact.Path $container.Platforms
        if ($image.Digest -cne $artifact.Digest) { throw 'Container image digest changed since packaging.' }
        $reference = "$($container.Image):$($container.Tag)"
        $existing = Get-AmithRegistryDigest $reference
        if ($existing -and $existing -cne $artifact.Digest) { throw "Container version tag already points to a different image: $reference" }
        if (-not $existing) {
            Invoke-AmithNative skopeo (@('copy','--all','--preserve-digests') + @(Get-AmithContainerAuthArguments) + @("oci-archive:$($artifact.Path)","docker://$reference")) $Plan.Root
        }
        if ((Get-AmithRegistryDigest $reference) -cne $artifact.Digest) { throw 'Registry digest verification failed after container publication.' }
        Save-AmithContainerPublication $Plan $reference $artifact.Digest
    }
    # Move aliases only after all immutable version tags have been verified.
    if ($latest) {
        foreach ($container in $containers) {
            $artifact = @($artifacts | Where-Object Project -ceq $container.Name)[0]
            $reference = "$($container.Image):latest"
            if ((Get-AmithRegistryDigest $reference) -cne $artifact.Digest) {
                Invoke-AmithNative skopeo (@('copy','--all','--preserve-digests') + @(Get-AmithContainerAuthArguments) + @("oci-archive:$($artifact.Path)","docker://$reference")) $Plan.Root
            }
            if ((Get-AmithRegistryDigest $reference) -cne $artifact.Digest) { throw 'Registry digest verification failed for latest.' }
            Save-AmithContainerPublication $Plan $reference $artifact.Digest
        }
    }
}
