@{
    Solution = 'MyLibrary.sln'
    Defaults = @{ Pack = $true }
    # Library packages have no RID: Linux hosts can build Windows-targeted libraries.
    Release = @{
        NuGet = @{
            Enabled = $true
            SourceEnvironment = 'NUGET_SOURCE_URL'
            ApiKeyEnvironment = 'NUGET_API_KEY'
        }
        # Set to true to prohibit releases when all tests were skipped on this host.
        RequireTestExecution = $false
    }
}
