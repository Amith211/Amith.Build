# Isolated context/cache fixtures: no SDK download and no consumer code execution.
$sdkFunctions=@{}
foreach($name in @('Resolve-AmithSdkRequirements','Get-AmithSdkSource','Get-AmithSdkProfile','Invoke-AmithNative')){
    $sdkFunctions[$name]=& $module {param($name)(Get-Item "Function:$name").ScriptBlock} $name
}
$sdkRoot=Join-Path $testRoot 'execution-sdk'
[void][IO.Directory]::CreateDirectory($sdkRoot)
Set-Content (Join-Path $sdkRoot 'global.json') '{}'
$sdkState=@{Root=$sdkRoot;ProfileRoot=(Join-Path $sdkRoot 'profile');Version='10.0.404';Fail=$false;Calls=[Collections.Generic.List[object]]::new()}
[void][IO.Directory]::CreateDirectory($sdkState.ProfileRoot)
& $module {
    param($state)
    $script:SdkExecutionFixture=$state
    function script:Resolve-AmithSdkRequirements {
        param($RootPath,$SdkVersion,$AdditionalSdks,$TargetFrameworks)
        $requested=if($SdkVersion -eq 'latest'){'11.0.100'}elseif($SdkVersion -eq 'auto' -and (Find-AmithGlobalJson $RootPath).Sdk.Count){''}else{'10.0.404'}
        return @{RequestedSdkVersion=$requested;InstallSdkVersions=@('11.0.100','10.0.404')}
    }
    function script:Get-AmithSdkSource {param($Version)return @{Version=$Version;Root=$script:SdkExecutionFixture.Root}}
    function script:Get-AmithSdkProfile {
        param($Sources,$SdkVersions)
        $script:SdkExecutionFixture.Calls.Add(@($SdkVersions))
        return @{Root=$script:SdkExecutionFixture.ProfileRoot;Dotnet=(Join-Path $script:SdkExecutionFixture.ProfileRoot $(if($IsWindows){'dotnet.exe'}else{'dotnet'}))}
    }
    function script:Invoke-AmithNative {
        param($File,$Arguments,$WorkingDirectory,[switch]$Capture,$SensitiveValues)
        if($script:SdkExecutionFixture.Fail){throw 'native SDK selection failed'}
        if($Arguments -contains '--version'){return $script:SdkExecutionFixture.Version}
    }
} $sdkState
try{
    Check 'SDK scopes restore native resolution and environment after success and failures' {
        $beforePath=$env:PATH;$beforeRoot=$env:DOTNET_ROOT
        $scope=& $module {param($root)Open-AmithSdkScope $root '10'} $sdkRoot
        try{
            Assert-Equal $sdkState.ProfileRoot $env:DOTNET_ROOT
            Assert-True $env:PATH.StartsWith($sdkState.ProfileRoot)
        }finally{& $module {param($scope)Close-AmithSdkScope $scope} $scope}
        Assert-Equal $beforePath $env:PATH;Assert-Equal $beforeRoot $env:DOTNET_ROOT
        $sdkState.Fail=$true
        try{Assert-Throws {& $module {param($root)Open-AmithSdkScope $root '10'} $sdkRoot} '*Cannot select*'}
        finally{$sdkState.Fail=$false}
        Assert-Equal $beforePath $env:PATH;Assert-Equal $beforeRoot $env:DOTNET_ROOT
    }
    Check 'native SDK mismatch is rejected instead of bypassing global.json' {
        Assert-Throws {& $module {param($root)Open-AmithSdkScope $root 'latest'} $sdkRoot} '*SDK conflict*'
    }
    Check 'SDK policy snapshots detect changes before saved-plan execution' {
        $scope=& $module {param($root)Open-AmithSdkScope $root '10'} $sdkRoot
        try{$execution=& $module {param($scope)Complete-AmithSdkScope $scope @('net10.0') @()} $scope}
        finally{& $module {param($scope)Close-AmithSdkScope $scope} $scope}
        Set-Content (Join-Path $sdkRoot 'global.json') '{"test":{"runner":"VSTest"}}'
        Assert-Throws {& $module {param($root,$execution)Open-AmithSdkScope -RootPath $root -Execution $execution} $sdkRoot $execution} '*changed since planning*'
    }
    Check 'SDK cache profiles retain runtime assets while exposing only requested SDKs' {
        # Use the real profile composer with dummy SDK payloads.
        & $module {param($body)Set-Item Function:script:Get-AmithSdkProfile $body} $sdkFunctions['Get-AmithSdkProfile']
        $source=Join-Path $sdkRoot 'source'
        foreach($directory in @('sdk/10.0.404','sdk/11.0.100','shared/Microsoft.NETCore.App/10.0.15','shared/Microsoft.NETCore.App/11.0.0','shared/Microsoft.NETCore.App/6.0.0')){
            [void][IO.Directory]::CreateDirectory((Join-Path $source $directory))
            Set-Content (Join-Path $source "$directory/dotnet.dll") "payload-$directory"
        }
        Set-Content (Join-Path $source $(if($IsWindows){'dotnet.exe'}else{'dotnet'})) 'host'
        $sources=@(@{Version='10.0.404';Root=$source},@{Version='11.0.100';Root=$source})
        $originalCache=$env:AMITH_TOOL_CACHE;$env:AMITH_TOOL_CACHE=Join-Path $sdkRoot 'cache'
        try{
            $profileResult=& $module {param($sources)Get-AmithSdkProfile $sources @('10.0.404')} $sources
            Assert-True (Test-Path (Join-Path $profileResult.Root 'sdk/10.0.404/dotnet.dll'))
            Assert-True (-not (Test-Path (Join-Path $profileResult.Root 'sdk/11.0.100')))
            Assert-True (Test-Path (Join-Path $profileResult.Root 'shared/Microsoft.NETCore.App/11.0.0/dotnet.dll'))
            Assert-True (-not (Test-Path (Join-Path $profileResult.Root 'shared/Microsoft.NETCore.App/6.0.0')))
            $again=& $module {param($sources)Get-AmithSdkProfile $sources @('10.0.404')} $sources
            Assert-Equal $profileResult.Root $again.Root
            Set-Content (Join-Path $profileResult.Root 'sdk/10.0.404/dotnet.dll') 'corrupt'
            $repaired=& $module {param($sources)Get-AmithSdkProfile $sources @('10.0.404')} $sources
            Assert-Equal 'payload-sdk/10.0.404' (Get-Content (Join-Path $repaired.Root 'sdk/10.0.404/dotnet.dll') -Raw).Trim()
        }finally{$env:AMITH_TOOL_CACHE=$originalCache}
    }
    Check 'SDK archive verification rejects incomplete downloads and retries without a poisoned cache' {
        & $module {param($body)Set-Item Function:script:Get-AmithSdkSource $body} $sdkFunctions['Get-AmithSdkSource']
        $requestType=& $module {(Get-Command Invoke-WebRequest).CommandType.ToString()}
        $extra=@{}
        foreach($name in @('Find-AmithInstalledSdk','Get-AmithSdkArchive')){$extra[$name]=& $module {param($name)(Get-Item "Function:$name").ScriptBlock} $name}
        $originalCache=$env:AMITH_TOOL_CACHE;$env:AMITH_TOOL_CACHE=Join-Path $sdkRoot 'download cache'
        try{
            & $module {
                function script:Find-AmithInstalledSdk {param($Version)return ''}
                function script:Get-AmithSdkArchive {param($Version,$Rid)return @{url='https://example.invalid/sdk';hash=('0'*128)}}
                function script:Invoke-WebRequest {param($Uri,$OutFile,$TimeoutSec,$ErrorAction)Set-Content -LiteralPath $OutFile -Value 'interrupted download'}
            }
            Assert-Throws {& $module {Get-AmithSdkSource '10.0.404'}} '*SHA512 mismatch*'
            Assert-Equal 0 @(Get-ChildItem $env:AMITH_TOOL_CACHE -Recurse -Directory -Filter '*.attempt-*').Count
            Assert-Equal 0 @(Get-ChildItem $env:AMITH_TOOL_CACHE -Recurse -File -Force -Filter '.amith-ready.json').Count
            # A second attempt must verify/download again rather than use the failed entry.
            Assert-Throws {& $module {Get-AmithSdkSource '10.0.404'}} '*SHA512 mismatch*'
        }finally{
            # Remove the visible function so later integration checks use the real cmdlet.
            & $module {Remove-Item Function:Invoke-WebRequest -Force}
            foreach($name in $extra.Keys){& $module {param($name,$body)Set-Item "Function:script:$name" $body} $name $extra[$name]}
            $env:AMITH_TOOL_CACHE=$originalCache
            Assert-Equal $requestType (& $module {(Get-Command Invoke-WebRequest).CommandType.ToString()})
        }
    }
}finally{
    foreach($name in $sdkFunctions.Keys){& $module {param($name,$body)Set-Item "Function:script:$name" $body} $name $sdkFunctions[$name]}
}
