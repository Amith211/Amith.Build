@{
    Discover = $false
    NoTests = $true # This example has no tests. Real applications should include theirs.
    Projects = @(@{ Path = 'Api/Api.csproj'; Publish = $false; Archive = $false })
    Containers = @(
        @{
            Name = 'api'
            Context = '.'
            Dockerfile = 'Dockerfile'
            Target = 'runtime'
            Image = 'harbor.example.com/applications/example-api'
            Platforms = @('linux/amd64')
            BuildArguments = @{ CONFIGURATION = 'Release' }
            # For private NuGet feeds, supply NUGET_RESTORE_SOURCES in CI and add:
            # Secrets = @(@{ Id = 'nuget_config'; Source = 'NuGetRestoreSources' })
        }
    )
    Release = @{ Containers = @{ Enabled = $true; TagAsLatest = $false } }
}
