# SDKs are portable installations. Profiles contain ordinary SDK/runtime files,
# so the native dotnet host still applies every global.json policy.
function Remove-AmithSdkCacheDirectory {
    param([string]$Path)
    $root=[IO.Path]::GetFullPath((Get-AmithToolCacheRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $full=[IO.Path]::GetFullPath($Path)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not $full.StartsWith($root,$comparison)){throw 'SDK cache operation escapes the tool cache root.'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}

function Invoke-AmithSdkCacheLock {
    param([string]$Directory,[scriptblock]$Body)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Directory))
    $lock=$null;$deadline=[DateTime]::UtcNow.AddMinutes(10)
    $lockWatch=[Diagnostics.Stopwatch]::StartNew();$lockNextReport=0
    while(-not $lock){
        try{$lock=[IO.File]::Open("$Directory.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException]{
            if($lockWatch.Elapsed.TotalSeconds -ge $lockNextReport){
                Write-Host ("[timing] Waiting for SDK cache lock {0} ({1:F1}s)" -f $Directory,$lockWatch.Elapsed.TotalSeconds)
                $lockNextReport=$lockWatch.Elapsed.TotalSeconds+30
            }
            if([DateTime]::UtcNow -ge $deadline){throw "Timed out waiting for SDK cache lock: $Directory"}
            Start-Sleep -Milliseconds 500
        }
    }
    if($lockNextReport -gt 0){Write-Host ("[timing] Acquired SDK cache lock after {0:F3}s" -f $lockWatch.Elapsed.TotalSeconds)}
    try{& $Body}finally{$lock.Dispose()}
}

function Get-AmithSdkHostRid {
    $arch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    if($arch -notin @('x64','arm64')){throw "SDK setup does not support process architecture '$arch'."}
    if($IsWindows){return "win-$arch"}
    if($IsLinux){
        if(Test-Path -LiteralPath '/etc/alpine-release'){return "linux-musl-$arch"}
        return "linux-$arch"
    }
    throw 'SDK setup currently supports Windows and Linux.'
}

function Get-AmithSdkExecutable {
    param([string]$Root)
    return Join-Path $Root $(if($IsWindows){'dotnet.exe'}else{'dotnet'})
}

function Get-AmithSdkArchive {
    param([string]$Version,[string]$Rid)
    $parts=Get-AmithSdkVersionParts $Version
    $url="https://builds.dotnet.microsoft.com/dotnet/release-metadata/$($parts.Channel)/releases.json"
    $document=Get-AmithDotNetJson $url
    foreach($release in @(Get-AmithValue $document 'releases' @())){
        $sdks=@((Get-AmithValue $release 'sdk' @{}))+@(Get-AmithValue $release 'sdks' @())
        foreach($sdk in $sdks){
            if((Get-AmithValue $sdk 'version' '') -cne $Version){continue}
            $file=@((Get-AmithValue $sdk 'files' @())|Where-Object{
                $_.rid -eq $Rid -and $_.name -like $(if($IsWindows){'*.zip'}else{'*.tar.gz'})
            }|Select-Object -First 1)
            if($file.Count){
                $uri=$null
                if(-not [uri]::TryCreate([string]$file[0].url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or
                    $uri.Host -notin @('builds.dotnet.microsoft.com','download.visualstudio.microsoft.com','dotnetcli.azureedge.net','dotnetcli.blob.core.windows.net') -or
                    [string]$file[0].hash -notmatch '^[a-fA-F0-9]{128}$'){throw 'Invalid Microsoft SDK archive metadata.'}
                return $file[0]
            }
        }
    }
    throw "Microsoft release metadata has no SDK $Version archive for $Rid."
}

function Find-AmithInstalledSdk {
    param([string]$Version)
    $commands=@(Get-Command dotnet -All -CommandType Application -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Source -Unique)
    foreach($command in $commands){
        try{
            $lines=@(Invoke-AmithNative $command @('--list-sdks') -Capture)
            foreach($line in $lines){
                if($line -match '^(\S+)\s+\[(.+)\]$' -and $Matches[1] -ceq $Version){
                    $root=Split-Path -Parent $Matches[2]
                    $info=@(Invoke-AmithNative (Get-AmithSdkExecutable $root) @('--info') -Capture) -join [char]10
                    $arch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
                    if($info -match "(?m)^\s*Architecture:\s+$arch\s*$"){return $root}
                }
            }
        }catch{continue}
    }
    return ''
}

function Get-AmithSdkSource {
    param([string]$Version)
    $null=Get-AmithSdkVersionParts $Version
    $rid=Get-AmithSdkHostRid
    $directory=Join-Path (Get-AmithToolCacheRoot) "amith-build/dotnet/versions/$rid/$Version"
    return Invoke-AmithSdkCacheLock $directory {
        $dll=Join-Path $directory "sdk/$Version/dotnet.dll"
        $marker=Join-Path $directory '.amith-ready.json'
        if((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $marker)){
            try{
                $receipt=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json -AsHashtable
                if($receipt.Sha256 -ceq (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -and
                    (Test-Path -LiteralPath (Get-AmithSdkExecutable $directory))){
                    Write-Host "SDK cache hit: $Version ($rid)"
                    return @{Version=$Version;Root=$directory}
                }
            }catch{}
        }
        $installed=Invoke-AmithTimed "Find installed SDK $Version" {Find-AmithInstalledSdk $Version}
        if($installed){Write-Host "Reusing installed SDK $Version ($rid)";return @{Version=$Version;Root=$installed}}
        $asset=Get-AmithSdkArchive $Version $rid
        $attempt="$directory.attempt-$([guid]::NewGuid().ToString('N'))"
        [void][IO.Directory]::CreateDirectory($attempt)
        try{
            $archive=Join-Path $attempt $(if($IsWindows){'sdk.zip'}else{'sdk.tar.gz'})
            Write-Host "Downloading SDK $Version ($rid)"
            Invoke-AmithTimed "Download SDK $Version ($rid)" {Invoke-WebRequest -Uri $asset.url -OutFile $archive -TimeoutSec 600 -ErrorAction Stop}
            if((Invoke-AmithTimed "Verify SDK $Version archive checksum" {(Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash}) -ine [string]$asset.hash){throw "SDK $Version archive SHA512 mismatch."}
            $unpack=Join-Path $attempt 'unpack';[void][IO.Directory]::CreateDirectory($unpack)
            Invoke-AmithTimed "Extract SDK $Version ($rid)" {
                if($IsWindows){[IO.Compression.ZipFile]::ExtractToDirectory($archive,$unpack)}
                else{Invoke-AmithNative tar @('-xzf',$archive,'-C',$unpack)}
            }
            $dll=Join-Path $unpack "sdk/$Version/dotnet.dll"
            if(-not (Test-Path -LiteralPath $dll)){throw 'SDK archive did not contain the requested SDK.'}
            $null=Invoke-AmithNative (Get-AmithSdkExecutable $unpack) @('--list-sdks') -Capture
            @{Sha256=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash}|ConvertTo-Json|Set-Content (Join-Path $unpack '.amith-ready.json')
            Remove-AmithSdkCacheDirectory $directory
            Move-Item -LiteralPath $unpack -Destination $directory
        }finally{Remove-AmithSdkCacheDirectory $attempt}
        return @{Version=$Version;Root=$directory}
    }
}

function Copy-AmithSdkSupportFiles {
    param([string]$Source,[string]$Destination,[string[]]$Channels)
    foreach($item in @(Get-ChildItem -LiteralPath $Source -Force)){
        if($item.Name -in @('sdk','.amith-ready.json','store','additionalDeps','swidtag')){continue}
        if($item.Name -in @('shared','packs')){
            foreach($package in @(Get-ChildItem -LiteralPath $item.FullName -Directory)){
                foreach($version in @(Get-ChildItem -LiteralPath $package.FullName -Directory)){
                    if($version.Name -notmatch '^(\d+\.\d+)\.' -or $Matches[1] -notin $Channels){continue}
                    $target=Join-Path $Destination "$($item.Name)/$($package.Name)"
                    [void][IO.Directory]::CreateDirectory($target)
                    Invoke-AmithTimed "Copy SDK support $($item.Name)/$($package.Name)/$($version.Name) from $Source" {
                        Copy-Item -LiteralPath $version.FullName -Destination $target -Recurse -Force
                    }
                }
            }
        }else{
            Invoke-AmithTimed "Copy SDK support $($item.Name) from $Source" {
                Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
            }
        }
    }
}
function Get-AmithSdkProfile {
    param([object[]]$Sources,[string[]]$SdkVersions)
    $rid=Get-AmithSdkHostRid
    $sourcesSorted=@($Sources|Sort-Object{[System.Management.Automation.SemanticVersion]::Parse($_.Version)})
    $identity=(@($sourcesSorted|ForEach-Object{$_.Version}) -join ',')+'|'+(@($SdkVersions|Sort-Object) -join ',')
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $directory=Join-Path (Get-AmithToolCacheRoot) "amith-build/dotnet/profiles/$rid/$key"
    return Invoke-AmithTimed "Prepare SDK profile $($key.Substring(0,12)) (SDKs: $($SdkVersions -join ', '))" {
        Invoke-AmithSdkCacheLock $directory {
            $marker=Join-Path $directory '.amith-ready.json'
            $executable=Get-AmithSdkExecutable $directory
            if((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $executable)){
                try{
                    $receipt=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json -AsHashtable
                    $valid=$receipt.HostHash -ceq (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
                    foreach($version in $SdkVersions){
                        $dll=Join-Path $directory "sdk/$version/dotnet.dll"
                        $valid=$valid -and (Test-Path -LiteralPath $dll) -and $receipt.SdkHashes[$version] -ceq (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
                    }
                    if($valid){Write-Host "SDK profile cache hit ($rid)";return @{Root=$directory;Dotnet=$executable}}
                }catch{}
            }
            $attempt="$directory.attempt-$([guid]::NewGuid().ToString('N'))"
            [void][IO.Directory]::CreateDirectory($attempt)
            try{
                # Preserve runtime packs, native files and SDK support directories.
                # Copy shared content once per source root, with the newest host last.
                $seen=@{}
                for($i=$sourcesSorted.Count-1;$i -ge 0;$i--){
                    $source=$sourcesSorted[$i]
                    if($seen.ContainsKey($source.Root)){continue}
                    $seen[$source.Root]=$true
                }
                foreach($source in $sourcesSorted){
                    if(-not $seen.ContainsKey($source.Root)){continue}
                    $newest=@($sourcesSorted|Where-Object Root -eq $source.Root)[-1].Version
                    if($source.Version -cne $newest){continue}
                    $channels=@($Sources|ForEach-Object{(Get-AmithSdkVersionParts $_.Version).Channel}|Select-Object -Unique)
                    Invoke-AmithTimed "Prepare support files from SDK $($source.Version) at $($source.Root)" {
                        Copy-AmithSdkSupportFiles $source.Root $attempt $channels
                    }
                    [void]$seen.Remove($source.Root)
                }
                $hashes=@{}
                foreach($version in $SdkVersions){
                    $source=@($Sources|Where-Object Version -ceq $version)[0]
                    $destination=Join-Path $attempt 'sdk';[void][IO.Directory]::CreateDirectory($destination)
                    Invoke-AmithTimed "Copy compiler SDK $version from $($source.Root)" {
                        Copy-Item -LiteralPath (Join-Path $source.Root "sdk/$version") -Destination $destination -Recurse -Force
                    }
                    $hashes[$version]=(Get-FileHash -LiteralPath (Join-Path $destination "$version/dotnet.dll") -Algorithm SHA256).Hash
                }
                $hostPath=Get-AmithSdkExecutable $attempt
                $null=Invoke-AmithTimed 'Validate prepared SDK profile host' {Invoke-AmithNative $hostPath @('--list-sdks') -Capture}
                @{HostHash=(Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash;SdkHashes=$hashes}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $attempt '.amith-ready.json')
                Remove-AmithSdkCacheDirectory $directory
                Move-Item -LiteralPath $attempt -Destination $directory
            }finally{Remove-AmithSdkCacheDirectory $attempt}
            Write-Host "Prepared SDK profile: $($SdkVersions -join ', ') ($rid)"
            return @{Root=$directory;Dotnet=$executable}
        }
    }
}

function Set-AmithSdkProfileEnvironment {
    param($sdkProfile)
    $script:AmithDotnetPath=$sdkProfile.Dotnet
    $env:PATH=$sdkProfile.Root+[IO.Path]::PathSeparator+$env:PATH
    $env:DOTNET_ROOT=$sdkProfile.Root
    $arch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToUpperInvariant()
    [Environment]::SetEnvironmentVariable("DOTNET_ROOT_$arch",$sdkProfile.Root)
    $env:DOTNET_HOST_PATH=$sdkProfile.Dotnet
    $env:DOTNET_MULTILEVEL_LOOKUP='0'
}

function Get-AmithSdkPolicySnapshot {
    param([string]$Directory)
    $global=Find-AmithGlobalJson $Directory
    return @{Path=$global.Path;Hash=$(if($global.Path){(Get-FileHash -LiteralPath $global.Path -Algorithm SHA256).Hash}else{''})}
}

function Assert-AmithSdkSelection {
    param($Execution,[string[]]$Directories)
    foreach($directory in @($Directories|Select-Object -Unique)){
        try{$actual=(@(Invoke-AmithNative $Execution.Dotnet @('--version') $directory -Capture) -join '').Trim()}
        catch{throw "SDK selection failed in '$directory'. Requested SDK '$($Execution.Version)' conflicts with global.json or is unavailable. Update the request/policy; bypassing global.json is not supported. $($_.Exception.Message)"}
        if($actual -cne $Execution.Version){throw "SDK conflict in '$directory': requested '$($Execution.Version)', native host selected '$actual'. Update sdk-version or global.json."}
    }
}

function Close-AmithSdkScope {
    param($Scope)
    $script:AmithDotnetPath=$Scope.PreviousDotnet
    $script:AmithSdkWorkingDirectory=$Scope.PreviousWorkingDirectory
    foreach($name in $Scope.Environment.Keys){
        if($null -eq $Scope.Environment[$name]){[Environment]::SetEnvironmentVariable($name,[NullString]::Value)}
        else{[Environment]::SetEnvironmentVariable($name,[string]$Scope.Environment[$name])}
    }
}

function Open-AmithSdkScope {
    param([string]$RootPath,[string]$SdkVersion='auto',[string[]]$AdditionalSdks=@(),$Execution=$null)
    $names=@('PATH','DOTNET_ROOT','DOTNET_HOST_PATH','DOTNET_MULTILEVEL_LOOKUP','DOTNET_ROOT_X64','DOTNET_ROOT_ARM64')
    $scope=@{Environment=@{};PreviousDotnet=$script:AmithDotnetPath;PreviousWorkingDirectory=$script:AmithSdkWorkingDirectory;Root=$RootPath;Selector=$SdkVersion;AdditionalSdks=$AdditionalSdks}
    foreach($name in $names){$scope.Environment[$name]=[Environment]::GetEnvironmentVariable($name)}
    try{
        if($Execution){
            foreach($directory in $Execution.Policies.Keys){
                $snapshot=Get-AmithSdkPolicySnapshot $directory
                $saved=$Execution.Policies[$directory]
                if($snapshot.Path -cne $saved.Path -or $snapshot.Hash -cne $saved.Hash){throw 'global.json changed since planning. Create a new build plan before continuing.'}
            }
            if(-not (Test-Path -LiteralPath $Execution.Dotnet)){throw 'The saved SDK profile is missing. Create a new build plan.'}
            $scope.Execution=$Execution
        }else{
            $global=Find-AmithGlobalJson $RootPath
            $bootstrapSelector=if($SdkVersion -eq 'auto' -and -not $global.Sdk.Count){'latest'}else{$SdkVersion}
            $requirements=Invoke-AmithTimed "Resolve bootstrap SDK requirements (selector: $bootstrapSelector; additional: $($AdditionalSdks -join ', '))" {
                Resolve-AmithSdkRequirements -RootPath $RootPath -SdkVersion $bootstrapSelector -AdditionalSdks $AdditionalSdks
            }
            Write-Host "[timing] Bootstrap SDK availability required: $($requirements.InstallSdkVersions -join ', ')"
            $scope.Sources=@(foreach($version in $requirements.InstallSdkVersions){Get-AmithSdkSource $version})
            $versions=if($requirements.RequestedSdkVersion){@($requirements.RequestedSdkVersion)}else{@($requirements.InstallSdkVersions)}
            if($SdkVersion -eq 'auto' -and -not $global.Sdk.Count){
                # Bootstrap with available stable SDKs so nested compatible
                # policies can evaluate, while the root uses the latest stable SDK.
                $ceiling=[System.Management.Automation.SemanticVersion]::Parse($requirements.RequestedSdkVersion)
                $versions=@($requirements.InstallSdkVersions|Where-Object{
                    -not $_.Contains('-') -and [System.Management.Automation.SemanticVersion]::Parse($_) -le $ceiling
                })
            }
            $sdkProfile=Get-AmithSdkProfile $scope.Sources $versions
            Set-AmithSdkProfileEnvironment $sdkProfile
            try{$actual=(@(Invoke-AmithNative $sdkProfile.Dotnet @('--version') $RootPath -Capture) -join '').Trim()}
            catch{throw "Cannot select an SDK under global.json in '$RootPath'. $($_.Exception.Message)"}
            if($requirements.RequestedSdkVersion -and $actual -cne $requirements.RequestedSdkVersion){throw "SDK conflict: requested '$($requirements.RequestedSdkVersion)', native host selected '$actual'."}
            $scope.Execution=@{Root=$sdkProfile.Root;Dotnet=$sdkProfile.Dotnet;Version=$actual;Selector=$SdkVersion;InstallSdkVersions=$requirements.InstallSdkVersions;Policies=@{}}
            $scope.GlobalPolicy=$global.Sdk.Count -gt 0
            Write-Host "SDK availability: $($requirements.InstallSdkVersions -join ', ')"
        }
        Set-AmithSdkProfileEnvironment $scope.Execution
        $script:AmithSdkWorkingDirectory=$RootPath
        if($Execution){Assert-AmithSdkSelection $Execution (@($RootPath)+@($Execution.Policies.Keys))}
        Write-Host ("{0} SDK selected: {1}" -f $(if($Execution){'Saved'}else{'Bootstrap'}), $scope.Execution.Version)
        return $scope
    }catch{Close-AmithSdkScope $scope;throw}
}

function Complete-AmithSdkScope {
    param($Scope,[string[]]$TargetFrameworks,[string[]]$ProjectDirectories)
    if($Scope.Selector -eq 'auto' -and -not $Scope.GlobalPolicy){
        $requirements=Invoke-AmithTimed "Resolve build SDK from frameworks: $(@($TargetFrameworks|Select-Object -Unique) -join ', ')" {
            Resolve-AmithSdkRequirements -RootPath $Scope.Root -SdkVersion auto -AdditionalSdks $Scope.AdditionalSdks -TargetFrameworks $TargetFrameworks
        }
        Write-Host "[timing] Build SDK availability required: $($requirements.InstallSdkVersions -join ', '); selected: $($requirements.RequestedSdkVersion)"
        $sources=@(foreach($version in $requirements.InstallSdkVersions){Get-AmithSdkSource $version})
        $sdkProfile=Get-AmithSdkProfile $sources @($requirements.RequestedSdkVersion)
        $Scope.Execution=@{Root=$sdkProfile.Root;Dotnet=$sdkProfile.Dotnet;Version=$requirements.RequestedSdkVersion;Selector=$Scope.Selector;InstallSdkVersions=$requirements.InstallSdkVersions;Policies=@{}}
        Set-AmithSdkProfileEnvironment $Scope.Execution
    }
    $directories=@($Scope.Root)+@($ProjectDirectories)
    Assert-AmithSdkSelection $Scope.Execution $directories
    foreach($directory in @($directories|Select-Object -Unique)){$Scope.Execution.Policies[$directory]=Get-AmithSdkPolicySnapshot $directory}
    Write-Host "Build SDK selected: $($Scope.Execution.Version)"
    return $Scope.Execution
}

function Write-AmithSdkGitHubEnvironment {
    param($Execution)
    if(-not $Execution){return}
    $values=@{DOTNET_ROOT=$Execution.Root;DOTNET_HOST_PATH=$Execution.Dotnet;DOTNET_MULTILEVEL_LOOKUP='0'}
    $arch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToUpperInvariant()
    $values["DOTNET_ROOT_$arch"]=$Execution.Root
    foreach($value in $values.Values){if([string]$value -match '[\r\n]'){throw 'SDK environment values must be single-line paths.'}}
    if($env:GITHUB_ENV){foreach($name in $values.Keys){Add-Content -LiteralPath $env:GITHUB_ENV -Value "$name=$($values[$name])" -Encoding utf8}}
    if($env:GITHUB_PATH){Add-Content -LiteralPath $env:GITHUB_PATH -Value $Execution.Root -Encoding utf8}
    if($env:GITHUB_OUTPUT){
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "sdk_version=$($Execution.Version)" -Encoding utf8
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "dotnet_root=$($Execution.Root)" -Encoding utf8
    }
}
