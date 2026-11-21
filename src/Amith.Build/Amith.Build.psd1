@{
    RootModule = 'Amith.Build.psm1'
    ModuleVersion = '0.2.0'
    GUID = '71d51256-467a-4cfb-a729-1825d9c40cef'
    Author = 'Amith211'
    Description = 'Shared, staged .NET builds, packages and releases for local use and GitHub Actions.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('New-AmithBuildPlan', 'Invoke-AmithBuild', 'Invoke-AmithBuildStage', 'Resolve-AmithSdkRequirements')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Prerelease = 'alpha.4'
        }
    }
}
