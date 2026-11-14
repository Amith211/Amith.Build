@{
    Discover = $false
    Projects = @(
        @{ Path = 'src/Client/Client.csproj'; Kind = 'Desktop'; Runtimes = @('win-x64') }
        @{ Path = 'src/Api/Api.csproj'; Kind = 'Web'; Runtimes = @('win-x64', 'linux-x64') }
        @{ Path = 'src/Contracts/Contracts.csproj'; Kind = 'Library'; Pack = $true }
        @{ Path = 'tests/Api.Tests/Api.Tests.csproj'; Kind = 'Test' }
    )
    Release = @{ GitHub = @{ Enabled = $true; Repository = 'Amith211/MyApp' } }
}
