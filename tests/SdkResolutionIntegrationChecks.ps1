Check 'live Microsoft metadata resolves exact historical SDKs without changing repository policy' {
    $root=Join-Path $testRoot 'live-sdk-metadata'
    [void][IO.Directory]::CreateDirectory($root)
    $file=Join-Path $root 'global.json'
    $policy='{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false},"test":{"runner":"Microsoft.Testing.Platform"}}'
    Set-Content -LiteralPath $file -Value $policy -NoNewline
    $r=Resolve-AmithSdkRequirements -RootPath $root -SdkVersion '10.0.100' -AdditionalSdks '10'
    Assert-Equal '10.0.100' $r.RequestedSdkVersion
    Assert-True ($r.InstallSdkVersions -contains '10.0.100')
    Assert-True ($r.SupportedSdkVersions -contains $r.BootstrapSdkVersion)
    Assert-True ($r.AdditionalSdkVersions[0] -match '^10\.0\.\d+$')
    Assert-True $r.RequiresGlobalJsonValidation
    Assert-Equal $policy (Get-Content -LiteralPath $file -Raw)
}
