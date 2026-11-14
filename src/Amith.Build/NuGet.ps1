function Read-AmithNuGetSources {
    param([string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return }
    try { $sources=ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate }
    catch { throw 'NUGET_RESTORE_SOURCES must be valid JSON. Use toJSON() for individual GitHub secrets.' }
    if ($sources -isnot [array]) { throw 'NUGET_RESTORE_SOURCES must be a JSON array.' }
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in $sources) {
        if ($source -isnot [Collections.IDictionary]) { throw 'Each NuGet source must be an object.' }
        foreach ($key in $source.Keys) {
            if ($key -cnotin @('name','url','username','password','validAuthenticationTypes')) { throw 'A NuGet source contains an unsupported property.' }
        }
        foreach ($key in @('name','url')) {
            if (-not $source.Contains($key) -or $source[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($source[$key]) -or $source[$key] -match '[\x00-\x1f]') { throw "Each NuGet source requires a nonempty string $key." }
        }
        if ($source.name -ne $source.name.Trim() -or -not $names.Add($source.name)) { throw 'NuGet source names must be unique and have no surrounding whitespace.' }
        $uri=$null
        if (-not [IO.Path]::IsPathFullyQualified($source.url) -and (-not [Uri]::TryCreate($source.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https'))) { throw 'NuGet sources require absolute HTTP(S) URLs or filesystem paths.' }
        if ($uri -and $uri.UserInfo) { throw 'Supply NuGet credentials separately from the source URL.' }
        $hasUser=$source.Contains('username'); $hasPassword=$source.Contains('password')
        if ($hasUser -ne $hasPassword) { throw 'Supply NuGet username and password together, or omit both.' }
        if ($hasUser) {
            foreach ($key in @('username','password')) {
                if ($source[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($source[$key]) -or $source[$key].Contains([char]0)) { throw 'NuGet credentials are empty or invalid. Check the calling repository secrets.' }
            }
        }
        if ($source.Contains('validAuthenticationTypes')) {
            if (-not $hasUser -or $source.validAuthenticationTypes -isnot [string]) { throw 'validAuthenticationTypes requires explicit credentials and a string value.' }
            $types=@($source.validAuthenticationTypes.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() })
            if (@($types | Where-Object { $_ -notin @('basic','negotiate','kerberos','ntlm','digest') }).Count) { throw 'Invalid NuGet validAuthenticationTypes.' }
            $source.validAuthenticationTypes=$types -join ','
        }
        $source
    }
}

function Protect-AmithNuGetValue {
    param([string] $Value)
    if ($env:GITHUB_ACTIONS -eq 'true' -and $Value) {
        $escaped=$Value.Replace('%','%25').Replace([string][char]13,'%0D').Replace([string][char]10,'%0A')
        Write-Host "::add-mask::$escaped"
    }
}

function Get-AmithNuGetConfigPath {
    if ($IsWindows) { return Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'NuGet/NuGet.Config' }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget/NuGet/NuGet.Config'
}

function Get-AmithNuGetChild {
    param([Xml.XmlNode] $Parent, [string] $Name)
    $children=@($Parent.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.Name -ieq $Name })
    if ($children.Count -gt 1) { throw 'NuGet configuration has duplicate sections or credential entries.' }
    if ($children.Count) { return $children[0] }
    return $null
}

function Set-AmithNuGetSetting {
    param([Xml.XmlElement] $Parent, [string] $Key, [string] $Value)
    $entries=@($Parent.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] -and $_.Name -ieq 'add' -and $_.GetAttribute('key') -ieq $Key })
    if ($entries.Count -gt 1) { throw 'NuGet configuration has duplicate source or credential keys.' }
    if ($entries.Count) { $entry=$entries[0] }
    else { $entry=$Parent.OwnerDocument.CreateElement('add'); $entry.SetAttribute('key',$Key); [void]$Parent.AppendChild($entry) }
    $entry.SetAttribute('value',$Value)
}

function Export-AmithNuGetVariable {
    param([string] $Name, [string] $Value, [string] $GitHubEnvPath)
    [Environment]::SetEnvironmentVariable($Name,$Value,'Process')
    if ($GitHubEnvPath) {
        do { $delimiter='AMITH_'+[guid]::NewGuid().ToString('N') } while ($delimiter -in @($Value -split '\r?\n'))
        $lf=[string][char]10
        [IO.File]::AppendAllText($GitHubEnvPath,"$Name<<$delimiter"+$lf+$Value+$lf+$delimiter+$lf,[Text.UTF8Encoding]::new($false))
    }
}

function Initialize-AmithNuGetSources {
    param([string] $SourcesJson, [string] $ConfigPath, [string] $GitHubEnvPath=$env:GITHUB_ENV)
    # Discard parser details so malformed secret JSON cannot appear in errors.
    Protect-AmithNuGetValue $SourcesJson
    $sources=@(Read-AmithNuGetSources $SourcesJson)
    if (-not $sources.Count) { Write-Host 'NuGet restore feeds: none supplied; existing configuration unchanged.'; return }
    if (-not $ConfigPath) { $ConfigPath=Get-AmithNuGetConfigPath }
    $ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
    $document=[Xml.XmlDocument]::new(); $document.PreserveWhitespace=$true; $document.XmlResolver=$null
    $existed=Test-Path -LiteralPath $ConfigPath -PathType Leaf
    if ($existed) {
        $settings=[Xml.XmlReaderSettings]::new(); $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit; $settings.XmlResolver=$null; $settings.MaxCharactersInDocument=4194304
        try {
            $reader=[Xml.XmlReader]::Create($ConfigPath,$settings)
            try { $document.Load($reader) } finally { $reader.Dispose() }
        } catch { throw 'Could not safely read the user NuGet configuration. Check its XML before feed setup.' }
    } else { [void]$document.AppendChild($document.CreateElement('configuration')) }
    $root=$document.DocumentElement
    if ($root.Name -ne 'configuration' -or $root.NamespaceURI) { throw 'NuGet configuration requires an unnamespaced configuration root.' }
    $packageSources=Get-AmithNuGetChild $root 'packageSources'
    if (-not $packageSources) { $packageSources=$document.CreateElement('packageSources'); [void]$root.AppendChild($packageSources) }
    if (-not $existed -and -not @($sources | Where-Object name -ieq 'nuget.org').Count) { Set-AmithNuGetSetting $packageSources 'nuget.org' 'https://api.nuget.org/v3/index.json' }
    $variables=@()
    foreach ($source in $sources) {
        Protect-AmithNuGetValue $source.url
        Set-AmithNuGetSetting $packageSources $source.name $source.url
        if (-not $source.Contains('username')) { continue }
        # Preserve the registered key's spelling so credential lookup remains
        # correct on case-sensitive platforms when updating an existing source.
        $registered=@($packageSources.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] -and $_.Name -ieq 'add' -and $_.GetAttribute('key') -ieq $source.name })[0]
        $sourceName=$registered.GetAttribute('key')
        Protect-AmithNuGetValue $source.username; Protect-AmithNuGetValue $source.password
        $identity=$ConfigPath+'|'+$sourceName.ToUpperInvariant()
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).Substring(0,24)
        $userVariable='AMITH_NUGET_'+$hash+'_USERNAME'; $passwordVariable='AMITH_NUGET_'+$hash+'_PASSWORD'
        $variables+=@(@{Name=$userVariable;Value=$source.username},@{Name=$passwordVariable;Value=$source.password})
        $credentials=Get-AmithNuGetChild $root 'packageSourceCredentials'
        if (-not $credentials) { $credentials=$document.CreateElement('packageSourceCredentials'); [void]$root.AppendChild($credentials) }
        $encodedName=[Xml.XmlConvert]::EncodeLocalName($sourceName)
        $entry=Get-AmithNuGetChild $credentials $encodedName
        if (-not $entry) { $entry=$document.CreateElement($encodedName); [void]$credentials.AppendChild($entry) }
        foreach ($old in @($entry.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] -and $_.Name -ieq 'add' -and $_.GetAttribute('key') -ieq 'Password' })) { [void]$entry.RemoveChild($old) }
        Set-AmithNuGetSetting $entry 'Username' "%$userVariable%"
        Set-AmithNuGetSetting $entry 'ClearTextPassword' "%$passwordVariable%"
        if ($source.Contains('validAuthenticationTypes')) { Set-AmithNuGetSetting $entry 'ValidAuthenticationTypes' $source.validAuthenticationTypes }
        if ([Environment]::GetEnvironmentVariable('NuGetPackageSourceCredentials_'+$sourceName)) { Write-Warning 'An existing NuGetPackageSourceCredentials variable takes precedence over configured credentials for a supplied feed.' }
    }
    foreach ($variable in $variables) { Export-AmithNuGetVariable $variable.Name $variable.Value $GitHubEnvPath }
    $parent=Split-Path -Parent $ConfigPath; [void][IO.Directory]::CreateDirectory($parent)
    $temporary=Join-Path $parent ('.amith-nuget-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $document.Save($temporary)
        if (-not $IsWindows) {
            $mode=if ($existed) { [IO.File]::GetUnixFileMode($ConfigPath) } else { [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite }
            [IO.File]::SetUnixFileMode($temporary,$mode)
        }
        if ($existed) { [IO.File]::Replace($temporary,$ConfigPath,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$ConfigPath) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    Write-Host "NuGet restore feeds: configured $($sources.Count) source(s); credential values remain in the job environment."
}

function Test-AmithNuGetEffectiveSources {
    param([string] $SourcesJson, [string] $WorkingDirectory)
    $sources=@(Read-AmithNuGetSources $SourcesJson)
    if (-not $sources.Count) { return }
    $start=[Diagnostics.ProcessStartInfo]::new(); $start.FileName='dotnet'; $start.WorkingDirectory=$WorkingDirectory
    $start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in @('nuget','list','source','--format','short')) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start(); $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit(); $lines=$output.GetAwaiter().GetResult() -split '\r?\n'; [void]$errorOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Could not inspect effective NuGet sources. Check repository NuGet configuration and SDK availability.' }
        for ($i=0; $i -lt $sources.Count; $i++) {
            if (-not @($lines | Where-Object { $_.Trim() -ceq ('E '+$sources[$i].url) }).Count) {
                Write-Warning "NuGet source entry $($i+1) is not enabled with its supplied URL at the workspace root. Check repository nuget.config clear/remove, source overrides or disabled sources. Repository policy has not been changed."
            }
        }
    } finally { $process.Dispose() }
}
