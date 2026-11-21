# Suite paths are repository-owned test roots; project references build their dependencies.
function Get-AmithTestSuites {
    param($Config, [string] $Root)
    $definitions = Get-AmithValue $Config 'TestSuites' @{}
    if ($definitions -isnot [Collections.IDictionary]) { throw 'TestSuites must be a map of suite names to test project paths.' }
    $suites = @{}
    foreach ($name in $definitions.Keys) {
        if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Test suite names must be simple names.' }
        $paths = @()
        foreach ($path in @($definitions[$name])) {
            if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetExtension($path) -notin @('.csproj','.fsproj','.vbproj')) {
                throw "Test suite '$name' requires repository-relative project paths."
            }
            $paths += Resolve-AmithContainerPath $Root $path
        }
        $suites[$name] = @($paths | Sort-Object -Unique)
    }
    return $suites
}

function Get-AmithContainerTestProjects {
    param($Containers, $Suites, $Policy, [string] $BuildMode)
    $paths = @()
    foreach ($container in $Containers) {
        $names = @(Get-AmithValue $container 'TestSuites' @())
        if ($BuildMode -eq 'containers' -and -not $names.Count -and -not ($Policy.NoTests -or $Policy.SkipTests)) {
            throw "Container '$($container.Name)' needs TestSuites in containers mode, or an explicit NoTests/SkipTests policy."
        }
        $containerPaths = @()
        foreach ($name in $names) {
            if ($name -isnot [string] -or -not $Suites.ContainsKey($name)) { throw "Unknown test suite '$name' for container '$($container.Name)'." }
            $containerPaths += @($Suites[$name])
        }
        if ($BuildMode -eq 'containers' -and -not $containerPaths.Count -and -not ($Policy.NoTests -or $Policy.SkipTests)) {
            throw "Container '$($container.Name)' has an empty test selection. Declare NoTests or SkipTests explicitly if intended."
        }
        $paths += $containerPaths
    }
    $paths | Sort-Object -Unique
}
