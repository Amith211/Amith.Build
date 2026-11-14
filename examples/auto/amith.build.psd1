@{
    Defaults = @{ VersionedArchives = $false }
    Solution = 'MySolution.sln'
    # New solution projects are discovered automatically. Tests are identified by MSBuild.
    Runtimes = @('win-x64', 'linux-x64')
    Exclude = @('samples/**', '**/Scratch.csproj')
    Overrides = @(
        # The library is built as a dependency but is not made into a package.
        @{ Match = 'src/Internal.*/*.csproj'; Pack = $false }
        @{ Match = '**/Desktop.Tests.csproj'; TestPlatforms = @('Windows') }
        @{ Match = 'src/Api/*.csproj'; Kind = 'Web'; SelfContained = $false }
    )
}
