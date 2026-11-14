@{
    Solution = 'MyDesktopApp.sln'
    Runtimes = @('win-x64', 'linux-x64')
    Defaults = @{ Pack = $false }
    Overrides = @(
        @{
            Match = 'src/Client/Client.csproj'
            Kind = 'Desktop'
            # Only this project's supported Windows targets are selected.
            Velopack = @{
                Enabled = $true
                PackId = 'MyDesktopApp'
                Authors = 'Amith'
                MainExe = 'Client.exe'
                Channel = 'win'
                # Defaults to true. No prior release/channel is a valid first release.
                # GH_TOKEN is needed for private repositories and release uploads.
                DownloadPrevious = $true
                # Adds to mandatory .pdb / development JSON / splash-image exclusions.
                Excludes = @('(^|[\\/])local-cache[\\/]')
                Repository = 'Amith211/MyDesktopApp'
            }
        }
        @{ Match = 'src/Api/Api.csproj'; Kind = 'Web'; Runtimes = @('win-x64', 'linux-x64') }
    )
    Release = @{ GitHub = @{ Enabled = $true; Repository = 'Amith211/MyDesktopApp' } }
}
