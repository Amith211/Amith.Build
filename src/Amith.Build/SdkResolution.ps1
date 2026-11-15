# Metadata resolution only: the .NET host remains responsible for global.json
# roll-forward and final SDK selection during execution setup.
function Get-AmithDotNetJson {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        return Invoke-AmithTimed "Read .NET metadata $(([uri]$Uri).AbsolutePath)" {
            Invoke-RestMethod -Uri $Uri -TimeoutSec 60 -MaximumRetryCount 2 -RetryIntervalSec 2 -ErrorAction Stop | ConvertTo-Json -Depth 80 | ConvertFrom-Json -AsHashtable -Depth 80
        }
    } catch { throw "Could not read Microsoft .NET release metadata from $($Uri): $($_.Exception.Message)" }
}

function Get-AmithSdkVersionParts {
    param([string]$Version)
    $match = [regex]::Match($Version, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-[0-9A-Za-z.-]+)?$')
    $parsed = $null
    if (-not $match.Success -or -not [System.Management.Automation.SemanticVersion]::TryParse($Version, [ref]$parsed) -or $parsed.ToString() -cne $Version) { throw "Invalid exact SDK version '$Version'. Use a full SDK version, a major/channel selector, latest, or auto." }
    return @{ Channel="$($match.Groups['major'].Value).$($match.Groups['minor'].Value)"; Version=$Version }
}

function Get-AmithSdkChannels {
    param($Index)
    $channels = @(Get-AmithValue $Index 'releases-index' @())
    if (-not $channels.Count) { throw 'Microsoft .NET release metadata contains no SDK channels.' }
    foreach ($channel in $channels) {
        $name = [string](Get-AmithValue $channel 'channel-version' '')
        $sdk = [string](Get-AmithValue $channel 'latest-sdk' '')
        if ($name -notmatch '^\d+\.\d+$' -or -not $sdk) { throw 'Microsoft .NET release metadata has an invalid SDK channel.' }
        $null = Get-AmithSdkVersionParts $sdk
    }
    return $channels
}

function Get-AmithStableSdkChannels {
    param([object[]]$Channels)
    return @($Channels | Where-Object {
        (Get-AmithValue $_ 'support-phase' '') -in @('active','maintenance') -and
        [string](Get-AmithValue $_ 'latest-sdk' '') -match '^\d+\.\d+\.\d+$'
    } | Sort-Object { [version]$_['channel-version'] } -Descending)
}

function Resolve-AmithSdkSelector {
    param([string]$Selector, [object[]]$Channels, [System.Collections.IDictionary]$Details)
    if ($Selector -eq 'latest') {
        $stable = @(Get-AmithStableSdkChannels $Channels)
        if (-not $stable.Count) { throw 'No supported stable .NET SDK is available in Microsoft release metadata.' }
        return [string]$stable[0]['latest-sdk']
    }
    if ($Selector -match '^(?<major>\d+)(?:\.(?<minor>\d+)(?:\.x)?)?$') {
        $major = [int]$Matches.major
        if ($Matches['minor']) {
            $name = "$major.$([int]$Matches['minor'])"
            $channel = @($Channels | Where-Object { $_['channel-version'] -eq $name })
        } else {
            $name = [string]$major
            $matching = @($Channels | Where-Object { ([version]$_['channel-version']).Major -eq $major } |
                Sort-Object { [version]$_['channel-version'] } -Descending)
            $stable = @($matching | Where-Object { [string]$_['latest-sdk'] -notmatch '-' })
            $channel = @(if ($stable.Count) { $stable[0] } elseif ($matching.Count) { $matching[0] })
        }
        if ($channel.Count -ne 1) { throw "No .NET SDK release channel '$name' was found. Supply an available sdk-version." }
        $version = [string]$channel[0]['latest-sdk']
        if ($version.Contains('-')) { throw "Channel '$name' has no stable SDK. Request an exact prerelease SDK version explicitly." }
        return $version
    }
    $parts = Get-AmithSdkVersionParts $Selector
    $channel = @($Channels | Where-Object { $_['channel-version'] -eq $parts.Channel })
    if ($channel.Count -ne 1) { throw "No release metadata was found for SDK '$Selector'." }
    if ([string]$channel[0]['latest-sdk'] -ceq $Selector) { return $Selector }
    $url = [string](Get-AmithValue $channel[0] 'releases.json' '')
    $uri = $null
    if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.Host -notin @('builds.dotnet.microsoft.com','dotnetcli.blob.core.windows.net')) {
        throw "Invalid Microsoft SDK release metadata address for channel '$($parts.Channel)'."
    }
    if (-not $Details.Contains($url)) { $Details[$url] = Get-AmithDotNetJson $url }
    $versions = foreach ($release in @(Get-AmithValue $Details[$url] 'releases' @())) {
        $sdk = Get-AmithValue $release 'sdk' @{}
        if (Get-AmithValue $sdk 'version' '') { [string]$sdk.version }
        foreach ($sdk in @(Get-AmithValue $release 'sdks' @())) {
            if (Get-AmithValue $sdk 'version' '') { [string]$sdk.version }
        }
    }
    if ($Selector -cnotin @($versions)) { throw "Exact SDK '$Selector' was not found in Microsoft release metadata." }
    return $Selector
}

function Find-AmithGlobalJson {
    param([string]$RootPath)
    $directory = Resolve-AmithPath $RootPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "SDK root directory does not exist: $directory" }
    while ($directory) {
        $file = Join-Path $directory 'global.json'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            try { $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop }
            catch { throw "Invalid global.json at $($file): $($_.Exception.Message)" }
            if ($document -isnot [System.Collections.IDictionary]) { throw "global.json must contain a JSON object: $file" }
            $sdk = Get-AmithValue $document 'sdk' @{}
            if ($sdk -isnot [System.Collections.IDictionary]) { throw "global.json sdk must be an object: $file" }
            $version = Get-AmithValue $sdk 'version' ''
            if ($sdk.Keys -ccontains 'version') {
                if ($version -isnot [string] -or -not $version) { throw "global.json sdk.version must be a full SDK version string: $file" }
                $null = Get-AmithSdkVersionParts $version
            }
            return @{Path=$file;Sdk=$sdk}
        }
        $parent = [IO.Directory]::GetParent($directory)
        $directory = if ($parent) { $parent.FullName } else { '' }
    }
    return @{Path='';Sdk=@{}}
}

function Get-AmithFrameworkSdkChannel {
    param([string[]]$TargetFrameworks)
    if (-not $TargetFrameworks.Count) { throw 'Cannot infer an SDK without successfully evaluated target frameworks. Supply sdk-version explicitly.' }
    $channels = @()
    foreach ($framework in $TargetFrameworks) {
        if ($framework -match '^net(?<major>[5-9]|[1-9]\d+)\.(?<minor>\d+)(?:-[A-Za-z0-9.-]+)?$' -or
            $framework -match '^netcoreapp(?<major>[1-3])\.(?<minor>\d+)(?:-[A-Za-z0-9.-]+)?$') {
            $channels += "$($Matches.major).$($Matches.minor)"
        } elseif ($framework -notmatch '^netstandard[12]\.\d+$' -and $framework -notmatch '^net[1-4]\d{1,2}$') {
            throw "Cannot infer SDK requirements from target framework '$framework'. Supply sdk-version explicitly."
        }
    }
    if (-not $channels.Count) { return '' }
    return [string]@($channels | Sort-Object { [version]$_ } -Descending)[0]
}

function Resolve-AmithSdkRequirements {
    [CmdletBinding()]
    param([ValidateNotNullOrEmpty()][string]$SdkVersion='auto', [string[]]$AdditionalSdks=@(),
          [string[]]$TargetFrameworks=@(), [ValidateNotNullOrEmpty()][string]$RootPath=(Get-Location).ProviderPath)
    $index = Get-AmithDotNetJson 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
    $index = $index | ConvertTo-Json -Depth 80 | ConvertFrom-Json -AsHashtable -Depth 80
    $channels = @(Get-AmithSdkChannels $index)
    $supported = @(Get-AmithStableSdkChannels $channels)
    if (-not $supported.Count) { throw 'No supported stable SDK is available for bootstrapping.' }
    $details = @{}
    $global = Find-AmithGlobalJson $RootPath
    $globalVersion = [string](Get-AmithValue $global.Sdk 'version' '')
    if ($globalVersion) { $globalVersion = Resolve-AmithSdkSelector $globalVersion $channels $details }
    $requested = ''
    $source = 'Explicit'
    if ($SdkVersion -eq 'auto') {
        if ($global.Sdk.Count) {
            # Do not imitate roll-forward. Install its baseline and pass the
            # untouched policy to the native host during execution setup.
            $source = 'GlobalJson'
        } else {
            $channel = Get-AmithFrameworkSdkChannel $TargetFrameworks
            if ($channel) { $requested = Resolve-AmithSdkSelector $channel $channels $details; $source = 'TargetFramework' }
            else {
                $lts = @($supported | Where-Object { $_['release-type'] -eq 'lts' })
                if (-not $lts.Count) { throw 'No supported stable LTS SDK is available for legacy targets.' }
                $requested = [string]$lts[0]['latest-sdk']; $source = 'LtsFallback'
            }
        }
    } else { $requested = Resolve-AmithSdkSelector $SdkVersion $channels $details }
    $additional = @()
    foreach ($selector in $AdditionalSdks) { $additional += Resolve-AmithSdkSelector $selector $channels $details }
    $install = @(@($supported | ForEach-Object { [string]$_['latest-sdk'] }) + $additional + @($requested,$globalVersion) |
        Where-Object { $_ } | Select-Object -Unique)
    return @{
        Selector=$SdkVersion;SelectionSource=$source;RequestedSdkVersion=$requested
        BootstrapSdkVersion=[string]$supported[0]['latest-sdk']
        SupportedSdkVersions=@($supported | ForEach-Object { [string]$_['latest-sdk'] })
        AdditionalSdkVersions=@($additional | Select-Object -Unique)
        InstallSdkVersions=$install;GlobalJson=$global
        RequiresGlobalJsonValidation=($global.Sdk.Count -gt 0)
    }
}
