@{
    Solution = 'MyLibrary.sln'
    Defaults = @{ Pack = $true }
    # For a solution with no test projects, explicitly add: NoTests = $true
    # Library packages have no RID: Linux hosts can build Windows-targeted libraries.
    Release = @{
        NuGet = @{
            Enabled = $true
            SourceEnvironment = 'NUGET_SOURCE_URL'
            ApiKeyEnvironment = 'NUGET_API_KEY'
        }
    }
}
