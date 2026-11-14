Check 'real NuGet restore authenticates through credential macros with no password stored in config' {
    $config=New-NuGetFixtureConfig;$root=Split-Path -Parent $config
    $packageStream=[IO.MemoryStream]::new()
    $zip=[IO.Compression.ZipArchive]::new($packageStream,[IO.Compression.ZipArchiveMode]::Create,$true)
    $nuspec='<package><metadata><id>Amith.RestoreFixture</id><version>1.0.0</version><authors>Amith</authors><description>Disposable restore test fixture.</description></metadata></package>'
    $writer=[IO.StreamWriter]::new($zip.CreateEntry('Amith.RestoreFixture.nuspec').Open())
    $writer.Write($nuspec);$writer.Dispose();$zip.Dispose()
    $package=[Convert]::ToBase64String($packageStream.ToArray());$packageStream.Dispose()
    $portFile=Join-Path $root 'server-port'
    $username='fixture-user';$password='fixture-";\&%Pat'
    $server=Start-Job -ArgumentList $portFile,$package,$nuspec,$username,$password -ScriptBlock {
        param($PortFile,$Package,$Nuspec,$Username,$Password)
        $ErrorActionPreference='Stop'
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
        $port=$listener.LocalEndpoint.Port
        [IO.File]::WriteAllText($PortFile,[string]$port)
        $expected='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Username+':'+$Password))
        try {
            while($true) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
                $client=$listener.AcceptTcpClient()
                try {
                    $stream=$client.GetStream();$stream.ReadTimeout=10000
                    $reader=[IO.StreamReader]::new($stream)
                    $request=$reader.ReadLine()
                    if(-not $request){continue}
                    $path=($request -split ' ')[1];$authorization=''
                    while($true) {
                        $line=$reader.ReadLine()
                        if(-not $line){break}
                        if($line.StartsWith('Authorization:',[StringComparison]::OrdinalIgnoreCase)){$authorization=$line.Substring(14).Trim()}
                    }
                    $status='200 OK';$extra='';$body=[byte[]]@()
                    if($authorization -cne $expected) {$status='401 Unauthorized';$extra='WWW-Authenticate: Basic realm="fixture"'+[char]13+[char]10}
                    else {
                        [IO.File]::AppendAllText($PortFile+'.requests',$path+[Environment]::NewLine)
                        switch -Regex ($path) {
                            '^/v3/index.json$' {$body=[Text.Encoding]::UTF8.GetBytes('{"version":"3.0.0","resources":[{"@id":"http://127.0.0.1:'+ $port +'/flat/","@type":"PackageBaseAddress/3.0.0"}]}');break}
                            '^/flat/amith.restorefixture/index.json$' {$body=[Text.Encoding]::UTF8.GetBytes('{"versions":["1.0.0"]}');break}
                            '\.nupkg$' {$body=[Convert]::FromBase64String($Package);break}
                            '\.nuspec$' {$body=[Text.Encoding]::UTF8.GetBytes($Nuspec);break}
                            default {$status='404 Not Found'}
                        }
                    }
                    $newline=[string][char]13+[char]10
                    $header='HTTP/1.1 '+$status+$newline+$extra+'Content-Length: '+$body.Length+$newline+'Connection: close'+$newline+$newline
                    $bytes=[Text.Encoding]::ASCII.GetBytes($header);$stream.Write($bytes);$stream.Write($body);$stream.Flush()
                } finally {$client.Dispose()}
            }
        } finally {$listener.Stop()}
    }
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        while(-not (Test-Path -LiteralPath $portFile)) {
            if([DateTime]::UtcNow -gt $deadline -or $server.State -eq 'Failed'){throw 'Local NuGet fixture server did not start.'}
            Start-Sleep -Milliseconds 100
        }
        $url='http://127.0.0.1:'+(Get-Content -LiteralPath $portFile -Raw)+'/v3/index.json'
        $json=ConvertTo-Json -InputObject @(@{name='Local Fixture';url=$url;username=$username;password=$password}) -Compress
        Initialize-AmithNuGetSources $json $config -GitHubEnvPath ''
        [xml]$xml=Get-Content -LiteralPath $config -Raw
        $sources=$xml.SelectSingleNode('/configuration/packageSources')
        foreach($other in @($sources.SelectNodes('add[@key!="Local Fixture"]'))){[void]$sources.RemoveChild($other)}
        [void]$sources.PrependChild($xml.CreateElement('clear'))
        # HTTP is permitted only for this disposable loopback fixture.
        $sources.SelectSingleNode('add').SetAttribute('allowInsecureConnections','true')
        $xml.Save($config)
        $project=Join-Path $root 'Fixture.csproj'
        Set-Content -LiteralPath $project -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><NuGetAudit>false</NuGetAudit></PropertyGroup><ItemGroup><PackageReference Include="Amith.RestoreFixture" Version="1.0.0"/></ItemGroup></Project>'
        $text=Get-Content -LiteralPath $config -Raw
        Assert-True (-not $text.Contains($password))
        $arguments=@('restore',$project,'--configfile',$config,'--packages',(Join-Path $root 'packages'),'--no-http-cache')
        & $module {param($arguments,$root,$password)Invoke-AmithNative dotnet $arguments $root -SensitiveValues @($password)} $arguments $root $password
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'packages/amith.restorefixture/1.0.0/amith.restorefixture.1.0.0.nupkg'))
        Assert-True ((Get-Content -LiteralPath ($portFile+'.requests') -Raw).Contains('.nupkg'))
    } finally {Stop-Job $server;Remove-Job $server -Force}
}
Check 'effective-source diagnostics preserve repository clear and disabled-source policy' {
    $config=New-NuGetFixtureConfig;$root=Split-Path -Parent $config
    $json='[{"name":"Example","url":"https://example.invalid/v3/index.json"}]'
    Set-Content -LiteralPath $config -Value '<configuration><packageSources><clear/></packageSources></configuration>'
    $before=Get-Content -LiteralPath $config -Raw
    $output=@(Test-AmithNuGetEffectiveSources $json $root 3>&1)
    Assert-True (($output|Out-String).Contains('Repository policy has not been changed'))
    Assert-Equal $before (Get-Content -LiteralPath $config -Raw)
    Set-Content -LiteralPath $config -Value '<configuration><packageSources><clear/><add key="Example" value="https://example.invalid/v3/index.json"/></packageSources></configuration>'
    $output=@(Test-AmithNuGetEffectiveSources $json $root 3>&1)
    Assert-Equal 0 $output.Count
}
