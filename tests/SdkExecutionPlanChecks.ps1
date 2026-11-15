Check 'SDK selection defaults to auto with additive config and CLI availability overrides' {
    $sdkRequests.Clear()
    $null=New-AmithBuildPlan -ConfigPath $configPath -Version 1.2.3
    Assert-Equal auto $sdkRequests[-1].Selector
    $config=Join-Path $fixture 'sdk-options.psd1'
    Set-Content $config '@{Discover=$false;Projects=@(''src/Lib/Lib.csproj'');SdkVersion=''10'';AdditionalSdks=@(''8'')}'
    $null=Invoke-AmithBuild -ConfigPath $config -Version 1.2.3 -PlanOnly -AdditionalSdks '9'
    Assert-Equal '10' $sdkRequests[-1].Selector
    Assert-Equal @('8','9') $sdkRequests[-1].Additional
    $null=Invoke-AmithBuild -ConfigPath $config -Version 1.2.3 -PlanOnly -SdkVersion latest
    Assert-Equal latest $sdkRequests[-1].Selector
}
Check 'SDK options on Invoke-AmithBuild create a fresh plan rather than silently reusing one' {
    $p=New-FixturePlan
    $sdkRequests.Clear()
    $null=Invoke-AmithBuild -PlanPath $p.PlanPath -Version 1.2.3 -ConfigPath $configPath -SdkVersion '10' -PlanOnly
    Assert-Equal '10' $sdkRequests[-1].Selector
}
