. (Join-Path $PSScriptRoot '../src/Amith.Build/NuGet.ps1')
$nugetEnvironment=@{}
foreach($item in @(Get-ChildItem Env: | Where-Object Name -like 'AMITH_NUGET_*')) { $nugetEnvironment[$item.Name]=$item.Value }
$originalActions=$env:GITHUB_ACTIONS
$env:GITHUB_ACTIONS='false'
function New-NuGetFixtureConfig {
    $directory=Join-Path $testRoot ('nuget-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    return Join-Path $directory 'NuGet.Config'
}
try {
    Check 'absent or empty NuGet feed arrays leave configuration and job environment untouched' {
        $config=New-NuGetFixtureConfig;$environment=Join-Path (Split-Path $config) 'github-env'
        foreach($value in @('','[]','  ')) { Initialize-AmithNuGetSources $value $config $environment }
        Assert-True (-not (Test-Path -LiteralPath $config));Assert-True (-not (Test-Path -LiteralPath $environment))
    }
    Check 'NuGet source validation rejects malformed incomplete and duplicate entries before mutation' {
        foreach($json in @(
            '{"password":"not-a-real-sensitive-value"',
            '{}','null','[null]','[{"name":"Bad"}]',
            '[{"name":"Bad","url":"https://example.invalid","username":"user"}]',
            '[{"name":"Bad","url":"https://example.invalid","password":"pat"}]',
            '[{"name":"Bad","url":"https://example.invalid","username":"","password":"pat"}]',
            '[{"name":"Bad","url":"https://example.invalid","username":"user","password":null}]',
            '[{"name":"Bad","url":"https://example.invalid","usernmae":"user"}]',
            '[{"name":"Bad","url":"https://example.invalid","validAuthenticationTypes":"basic"}]',
            '[{"name":"Bad","url":"https://example.invalid","username":"user","password":"pat","validAuthenticationTypes":"custom"}]',
            '[{"name":"Bad","url":"https://user:password@example.invalid"}]',
            '[{"name":"Bad","url":"relative/path"}]',
            '[{"name":"Same","url":"https://example.invalid"},{"name":"same","url":"https://example.invalid"}]',
            '[{"name":"Valid","url":"https://example.invalid"},{"name":"Invalid"}]'
        )) {
            $config=New-NuGetFixtureConfig;$environment=Join-Path (Split-Path $config) 'github-env'
            Assert-Throws {Initialize-AmithNuGetSources $json $config $environment}
            Assert-True (-not (Test-Path -LiteralPath $config));Assert-True (-not (Test-Path -LiteralPath $environment))
        }
        try {Read-AmithNuGetSources '{"password":"not-a-real-sensitive-value"'} catch {Assert-True (-not ($_ | Out-String).Contains('not-a-real-sensitive-value'))}
    }
    Check 'NuGet credentials survive JSON escaping while only macros enter configuration' {
        $config=New-NuGetFixtureConfig;$environment=Join-Path (Split-Path $config) 'github-env'
        $username='fixture"user<&';$password='fixture\";=<&%long-secret'+[char]10+'next-line'
        $json=ConvertTo-Json -InputObject @(@{name='Example Feed';url='https://example.invalid/v3/index.json';username=$username;password=$password},@{name='Public';url='https://public.example.invalid/v3/index.json'}) -Compress
        $output=@(Initialize-AmithNuGetSources $json $config $environment 6>&1)
        $text=Get-Content -LiteralPath $config -Raw
        Assert-True (-not $text.Contains($username));Assert-True (-not $text.Contains($password))
        Assert-True (-not ($output|Out-String).Contains($username));Assert-True (-not ($output|Out-String).Contains($password))
        [xml]$xml=$text;$entry=$xml.SelectSingleNode('/configuration/packageSourceCredentials/Example_x0020_Feed')
        $userVariableName=$entry.SelectSingleNode('add[@key="Username"]').GetAttribute('value').Trim('%')
        $passwordName=$entry.SelectSingleNode('add[@key="ClearTextPassword"]').GetAttribute('value').Trim('%')
        Assert-Equal $username ([Environment]::GetEnvironmentVariable($userVariableName))
        Assert-Equal $password ([Environment]::GetEnvironmentVariable($passwordName))
        Assert-True ($null -eq $entry.SelectSingleNode('add[@key="ValidAuthenticationTypes"]'))
        Assert-True ($null -eq $xml.SelectSingleNode('/configuration/packageSourceCredentials/Public'))
        Assert-True ($null -ne $xml.SelectSingleNode('/configuration/packageSources/add[@key="nuget.org"]'))
        $export=Get-Content -LiteralPath $environment -Raw
        Assert-True ($export.Contains($passwordName+'<<'));Assert-True ($export.Contains($password))
        $firstBytes=[IO.File]::ReadAllBytes($environment);Assert-True (-not ($firstBytes[0] -eq 239 -and $firstBytes[1] -eq 187))
    }
    Check 'feed registration is repeatable and preserves unrelated NuGet policy and external credentials' {
        $config=New-NuGetFixtureConfig
        Set-Content -LiteralPath $config -Value '<configuration><!--preserve--><packageSources><add key="Example" value="https://old.example.invalid"/><add key="Other" value="https://other.example.invalid"/></packageSources><packageSourceCredentials><Example><add key="Username" value="old"/><add key="Password" value="old-encrypted"/><add key="ValidAuthenticationTypes" value="basic"/></Example><External><add key="ClearTextPassword" value="%EXTERNAL_PASSWORD%"/></External></packageSourceCredentials><disabledPackageSources><add key="Other" value="true"/></disabledPackageSources><packageSourceMapping><packageSource key="Example"><package pattern="Example.*"/></packageSource></packageSourceMapping><clientCertificates><add packageSource="External" path="fixture-cert"/></clientCertificates></configuration>'
        $json='[{"name":"Example","url":"https://new.example.invalid","username":"fixture-user","password":"fixture-pat"},{"name":"External","url":"https://external.example.invalid"}]'
        Initialize-AmithNuGetSources $json $config -GitHubEnvPath ''
        $first=Get-Content -LiteralPath $config -Raw
        Initialize-AmithNuGetSources $json $config -GitHubEnvPath ''
        Assert-Equal $first (Get-Content -LiteralPath $config -Raw)
        [xml]$xml=$first
        Assert-Equal 1 $xml.SelectNodes('/configuration/packageSources/add[@key="Example"]').Count
        Assert-True ($null -eq $xml.SelectSingleNode('/configuration/packageSourceCredentials/Example/add[@key="Password"]'))
        Assert-Equal 'basic' $xml.SelectSingleNode('/configuration/packageSourceCredentials/Example/add[@key="ValidAuthenticationTypes"]').GetAttribute('value')
        Assert-Equal '%EXTERNAL_PASSWORD%' $xml.SelectSingleNode('/configuration/packageSourceCredentials/External/add').GetAttribute('value')
        Assert-True ($null -ne $xml.SelectSingleNode('/configuration/packageSourceMapping'))
        Assert-True ($null -ne $xml.SelectSingleNode('/configuration/clientCertificates'))
        Assert-True ($first.Contains('<!--preserve-->'))
        Assert-Equal 'true' $xml.SelectSingleNode('/configuration/disabledPackageSources/add').GetAttribute('value')
    }
    Check 'credential entries retain existing source-name spelling on case-sensitive hosts' {
        $config=New-NuGetFixtureConfig
        Set-Content -LiteralPath $config -Value '<configuration><packageSources><add key="ExistingFeed" value="https://old.example.invalid"/></packageSources></configuration>'
        Initialize-AmithNuGetSources '[{"name":"existingfeed","url":"https://new.example.invalid","username":"fixture-user","password":"fake-pat"}]' $config -GitHubEnvPath ''
        [xml]$xml=Get-Content -LiteralPath $config -Raw
        Assert-Equal 'ExistingFeed' $xml.SelectSingleNode('/configuration/packageSources/add').GetAttribute('key')
        Assert-True ($null -ne $xml.SelectSingleNode('/configuration/packageSourceCredentials/ExistingFeed'))
    }
    Check 'optional NuGet authentication restrictions can be explicitly updated' {
        $config=New-NuGetFixtureConfig
        Initialize-AmithNuGetSources '[{"name":"Token","url":"https://example.invalid","username":"fixture","password":"fake-pat","validAuthenticationTypes":"Basic, Negotiate"}]' $config -GitHubEnvPath ''
        [xml]$xml=Get-Content -LiteralPath $config -Raw
        Assert-Equal 'basic,negotiate' $xml.SelectSingleNode('/configuration/packageSourceCredentials/Token/add[@key="ValidAuthenticationTypes"]').GetAttribute('value')
    }
    Check 'invalid user configuration is never overwritten' {
        foreach($text in @('<configuration><broken></configuration>','<!DOCTYPE configuration [<!ENTITY x SYSTEM "file:///not-read">]><configuration>&x;</configuration>','<other/>')) {
            $config=New-NuGetFixtureConfig;Set-Content -LiteralPath $config -Value $text
            $before=[IO.File]::ReadAllText($config)
            Assert-Throws {Initialize-AmithNuGetSources '[{"name":"Example","url":"https://example.invalid"}]' $config -GitHubEnvPath ''}
            Assert-Equal $before ([IO.File]::ReadAllText($config))
        }
    }
    if (-not $IsWindows) {
        Check 'updating NuGet configuration preserves restrictive Unix permissions' {
            $config=New-NuGetFixtureConfig
            Set-Content -LiteralPath $config -Value '<configuration/>'
            $mode=[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
            [IO.File]::SetUnixFileMode($config,$mode)
            Initialize-AmithNuGetSources '[{"name":"Example","url":"https://example.invalid"}]' $config -GitHubEnvPath ''
            Assert-Equal $mode ([IO.File]::GetUnixFileMode($config))
        }
    }
    Check 'existing higher-priority credential environment values are preserved and reported' {
        $config=New-NuGetFixtureConfig;$name='NuGetPackageSourceCredentials_Example'
        $prior=[Environment]::GetEnvironmentVariable($name)
        try {
            [Environment]::SetEnvironmentVariable($name,'Username=external;Password=fake-external')
            $output=@(Initialize-AmithNuGetSources '[{"name":"Example","url":"https://example.invalid","username":"fixture","password":"fake-pat"}]' $config -GitHubEnvPath '' 3>&1)
            Assert-True (($output|Out-String).Contains('takes precedence'))
            Assert-Equal 'Username=external;Password=fake-external' ([Environment]::GetEnvironmentVariable($name))
        } finally {[Environment]::SetEnvironmentVariable($name,$prior)}
    }
    if($Integration) { . (Join-Path $PSScriptRoot 'NuGetIntegrationChecks.ps1') }
} finally {
    foreach($item in @(Get-ChildItem Env: | Where-Object Name -like 'AMITH_NUGET_*')) {
        if(-not $nugetEnvironment.Contains($item.Name)) {[Environment]::SetEnvironmentVariable($item.Name,$null)}
    }
    foreach($name in $nugetEnvironment.Keys) {[Environment]::SetEnvironmentVariable($name,$nugetEnvironment[$name])}
    $env:GITHUB_ACTIONS=$originalActions
}
