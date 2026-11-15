# Offline metadata fixtures; do not depend on the currently supported .NET list.
$sdkOriginalMetadata=& $module { (Get-Item Function:Get-AmithDotNetJson).ScriptBlock }
$sdkMetadata=@{Calls=[Collections.Generic.List[string]]::new();Index=@{'releases-index'=@(
    @{'channel-version'='12.0';'latest-sdk'='12.0.100-preview.1';'support-phase'='preview';'release-type'='lts';'releases.json'='https://builds.dotnet.microsoft.com/dotnet/release-metadata/12.0/releases.json'},
    @{'channel-version'='11.0';'latest-sdk'='11.0.100';'support-phase'='active';'release-type'='sts';'releases.json'='https://builds.dotnet.microsoft.com/dotnet/release-metadata/11.0/releases.json'},
    @{'channel-version'='10.0';'latest-sdk'='10.0.404';'support-phase'='maintenance';'release-type'='lts';'releases.json'='https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'},
    @{'channel-version'='8.0';'latest-sdk'='8.0.428';'support-phase'='eol';'release-type'='lts';'releases.json'='https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json'}
)}}
& $module {
    param($state)
    $script:SdkMetadataFixture=$state
    Set-Item Function:script:Get-AmithDotNetJson -Value {
        param([string]$Uri)
        $script:SdkMetadataFixture.Calls.Add($Uri)
        if($Uri.EndsWith('releases-index.json')){return $script:SdkMetadataFixture.Index}
        if($Uri.Contains('/10.0/')){return @{releases=@(@{sdk=@{version='10.0.100'};sdks=@(@{version='10.0.301'},@{version='10.0.404'})})}}
        if($Uri.Contains('/12.0/')){return @{releases=@(@{sdk=@{version='12.0.100-preview.1'}})}}
        throw 'Unexpected metadata request'
    }
} $sdkMetadata
function New-SdkFixtureRoot {
    $root=Join-Path $testRoot ('sdk-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    Set-Content (Join-Path $root 'global.json') '{}'
    return $root
}
try {
    Check 'auto SDK uses the highest evaluated modern target including platform suffixes' {
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -TargetFrameworks netstandard2.0,net8.0,net10.0-windows10.0.19041.0
        Assert-Equal TargetFramework $r.SelectionSource
        Assert-Equal '10.0.404' $r.RequestedSdkVersion
        Assert-Equal '11.0.100' $r.BootstrapSdkVersion
        Assert-Equal @('11.0.100','10.0.404') $r.SupportedSdkVersions
    }
    Check 'major channel and exact SDK selectors resolve independently of targets' {
        foreach($selector in @('10','10.0','10.0.x','10.0.404')){
            $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion $selector -TargetFrameworks Unknown
            Assert-Equal '10.0.404' $r.RequestedSdkVersion
            Assert-Equal Explicit $r.SelectionSource
        }
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion latest
        Assert-Equal '11.0.100' $r.RequestedSdkVersion
    }
    Check 'major SDK selector chooses the highest stable minor channel within its major' {
        $original=$sdkMetadata.Index
        try {
            $sdkMetadata.Index=@{'releases-index'=@($original['releases-index'])+@(@{'channel-version'='10.1';'latest-sdk'='10.1.100';'support-phase'='active';'release-type'='sts'})}
            $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10'
            Assert-Equal '10.1.100' $r.RequestedSdkVersion
            $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10.0'
            Assert-Equal '10.0.404' $r.RequestedSdkVersion
        } finally {$sdkMetadata.Index=$original}
    }
    Check 'exact historical SDKs are validated against all SDK entries in release metadata' {
        $sdkMetadata.Calls.Clear()
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10.0.301' -AdditionalSdks '10.0.100','10.0.301'
        Assert-Equal '10.0.301' $r.RequestedSdkVersion
        Assert-Equal @('11.0.100','10.0.404','10.0.100','10.0.301') $r.InstallSdkVersions
        Assert-Equal 1 @($sdkMetadata.Calls|Where-Object{$_ -like '*/10.0/releases.json'}).Count
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10.0.999'} '*not found*'
    }
    Check 'additional SDKs add and deduplicate without changing the selected SDK' {
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10' -AdditionalSdks '8','8.0.428','latest','10'
        Assert-Equal '10.0.404' $r.RequestedSdkVersion
        Assert-Equal @('8.0.428','11.0.100','10.0.404') $r.AdditionalSdkVersions
        Assert-Equal @('11.0.100','10.0.404','8.0.428') $r.InstallSdkVersions
    }
    Check 'legacy-only targets use latest supported stable LTS SDK' {
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -TargetFrameworks netstandard2.0,netstandard2.1,net48,net472
        Assert-Equal LtsFallback $r.SelectionSource
        Assert-Equal '10.0.404' $r.RequestedSdkVersion
    }
    Check 'unknown or missing evaluated targets fail instead of guessing' {
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot)} '*successfully evaluated*'
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -TargetFrameworks net10.0,Unknown} '*Unknown*'
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -TargetFrameworks net99.0} '*99.0*'
    }
    Check 'unsupported channels need explicit requests and previews need exact versions' {
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '8'
        Assert-Equal '8.0.428' $r.RequestedSdkVersion
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '12'} '*exact prerelease*'
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '12.0.100-preview.1'
        Assert-Equal '12.0.100-preview.1' $r.RequestedSdkVersion
    }
    Check 'selectors reject wildcard shortcuts shell text and invalid additional SDKs' {
        foreach($selector in @('10.*.*','v10.0.100','10;echo','auto ','')){
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion $selector}
        }
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10' -AdditionalSdks auto}
    }
    Check 'global.json baseline and full SDK policy are preserved without editing any source' {
        $root=New-SdkFixtureRoot
        $file=Join-Path $root 'global.json'
        $text='{/* preserved */"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false,"paths":["$host$"]},"test":{"runner":"Microsoft.Testing.Platform"}}'
        Set-Content $file $text -NoNewline
        $r=Resolve-AmithSdkRequirements -RootPath $root
        Assert-Equal GlobalJson $r.SelectionSource
        Assert-Equal '' $r.RequestedSdkVersion
        Assert-True $r.RequiresGlobalJsonValidation
        Assert-Equal latestFeature $r.GlobalJson.Sdk.rollForward
        Assert-Equal @('$host$') $r.GlobalJson.Sdk.paths
        Assert-True ($r.InstallSdkVersions -contains '10.0.100')
        Assert-Equal $text (Get-Content $file -Raw)
    }
    Check 'explicit SDK with global.json retains both requirements for native conflict validation' {
        $root=New-SdkFixtureRoot
        Set-Content (Join-Path $root 'global.json') '{"sdk":{"version":"10.0.100","rollForward":"disable"}}'
        $r=Resolve-AmithSdkRequirements -RootPath $root -SdkVersion '11'
        Assert-Equal '11.0.100' $r.RequestedSdkVersion
        Assert-Equal '10.0.100' $r.GlobalJson.Sdk.version
        Assert-True $r.RequiresGlobalJsonValidation
    }
    Check 'global.json discovery walks ancestors and nearest file stops the search' {
        $root=New-SdkFixtureRoot
        Set-Content (Join-Path $root 'global.json') '{"sdk":{"version":"10.0.100"}}'
        $child=Join-Path $root 'nested/deeper';[void][IO.Directory]::CreateDirectory($child)
        $r=Resolve-AmithSdkRequirements -RootPath $child
        Assert-Equal (Join-Path $root 'global.json') $r.GlobalJson.Path
        Set-Content (Join-Path $child 'global.json') '{"test":{"runner":"VSTest"}}'
        $r=Resolve-AmithSdkRequirements -RootPath $child -TargetFrameworks net10.0
        Assert-Equal TargetFramework $r.SelectionSource
        Assert-True (-not $r.RequiresGlobalJsonValidation)
    }
    Check 'relative roots resolve from the PowerShell location and missing roots fail' {
        $root=New-SdkFixtureRoot
        Push-Location $root
        try {
            $r=Resolve-AmithSdkRequirements -RootPath '.' -SdkVersion '10'
            Assert-Equal (Join-Path $root 'global.json') $r.GlobalJson.Path
        } finally {Pop-Location}
        Assert-Throws {Resolve-AmithSdkRequirements -RootPath (Join-Path $root 'missing') -SdkVersion '10'} '*root directory does not exist*'
    }
    Check 'malformed global.json is reported and never bypassed' {
        foreach($json in @('{broken','[]','[{}]','{"sdk":null}','{"sdk":{"version":"10"}}','{"sdk":{"version":10}}','{"sdk":{"version":null}}')){
            $root=New-SdkFixtureRoot;Set-Content (Join-Path $root 'global.json') $json
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath $root -SdkVersion '11'}
        }
    }
    Check 'preview and end-of-life releases are excluded from automatic supported installation' {
        $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion latest
        Assert-Equal @('11.0.100','10.0.404') $r.InstallSdkVersions
    }
    Check 'untrusted release metadata URLs are rejected before channel requests' {
        $channel=$sdkMetadata.Index['releases-index'][2]
        $original=$channel['releases.json']
        try {
            $channel['releases.json']='https://example.invalid/releases.json'
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10.0.100'} '*Invalid Microsoft*'
        } finally {$channel['releases.json']=$original}
    }
    Check 'historical release channels with differently numbered SDKs do not break modern resolution' {
        $original=$sdkMetadata.Index
        try {
            $sdkMetadata.Index=@{'releases-index'=@($original['releases-index'])+@(@{'channel-version'='2.0';'latest-sdk'='2.1.202';'support-phase'='eol';'release-type'='sts'})}
            $r=Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion '10'
            Assert-Equal '10.0.404' $r.RequestedSdkVersion
        } finally {$sdkMetadata.Index=$original}
    }
    Check 'missing LTS fallback and malformed channel metadata fail clearly' {
        $original=$sdkMetadata.Index
        try {
            $sdkMetadata.Index=@{'releases-index'=@($original['releases-index'][1])}
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -TargetFrameworks netstandard2.0} '*No supported stable LTS*'
            $sdkMetadata.Index=@{'releases-index'=@(@{'channel-version'='broken';'latest-sdk'='11.0.100'})}
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion latest} '*invalid SDK channel*'
        } finally {$sdkMetadata.Index=$original}
    }
    Check 'no supported metadata fails clearly instead of choosing previews or EOL versions' {
        $original=$sdkMetadata.Index
        try {
            $sdkMetadata.Index=@{'releases-index'=@($original['releases-index'][0],$original['releases-index'][3])}
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion latest} '*No supported stable*'
            $sdkMetadata.Index=@{'releases-index'=@()}
            Assert-Throws {Resolve-AmithSdkRequirements -RootPath (New-SdkFixtureRoot) -SdkVersion latest} '*no SDK channels*'
        } finally {$sdkMetadata.Index=$original}
    }
} finally {
    & $module {param($original)Set-Item Function:script:Get-AmithDotNetJson -Value $original} $sdkOriginalMetadata
}
