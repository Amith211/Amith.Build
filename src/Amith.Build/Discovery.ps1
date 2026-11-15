function Get-AmithProjectMetadata {
    param([string] $Path, [string] $Configuration, [string] $Version)
    $properties = 'OutputType,IsTestProject,IsPackable,TargetFramework,TargetFrameworks,RuntimeIdentifier,RuntimeIdentifiers,UseWPF,UseWindowsForms,UsingMicrosoftNETSdkWeb,PackageId,AssemblyName,ProjectAssetsFile,CustomAfterMicrosoftCommonTargets'
    $lines = @(Invoke-AmithNative dotnet @('msbuild', $Path, '-nologo', "-p:Configuration=$Configuration", "-p:Version=$Version", '-p:EnableWindowsTargeting=true', "-getProperty:$properties", '-getItem:PackageReference') -Capture)
    $text = $lines -join "`n"
    $match = [regex]::Match($text, '(?s)\{.*\}')
    if (-not $match.Success) { throw "MSBuild did not return evaluated project properties for $Path" }
    $evaluated = ConvertFrom-Json -InputObject $match.Value -AsHashtable
    $metadata = $evaluated.Properties
    $references = @(Get-AmithValue (Get-AmithValue $evaluated 'Items' @{}) 'PackageReference' @())
    $metadata.TestPackages = @($references | ForEach-Object { [string](Get-AmithValue $_ 'Identity' '') })
    return $metadata
}

function Get-AmithSolutionProjects {
    param([string] $Solution)
    $lines = @(Invoke-AmithNative dotnet @('sln', $Solution, 'list') -Capture)
    foreach ($line in $lines) {
        $relative = $line.Trim()
        if ($relative -match '\.(csproj|fsproj|vbproj)$') { Resolve-AmithPath $relative (Split-Path -Parent $Solution) }
    }
}

function Get-AmithProjectPlan {
    param([string] $Path, $Settings, [string] $Root, [string] $Configuration, [string[]] $DefaultRuntimes, [string] $Version, [System.Collections.IDictionary] $DeploymentOverrides = @{})
    $metadata = Get-AmithProjectMetadata $Path $Configuration $Version
    $frameworkText = [string](Get-AmithValue $metadata 'TargetFrameworks' '')
    if (-not $frameworkText) { $frameworkText = [string](Get-AmithValue $metadata 'TargetFramework' '') }
    $frameworks = @($frameworkText -split ';' | ForEach-Object Trim | Where-Object { $_ })
    $frameworks = @(Get-AmithValue $Settings 'Frameworks' $frameworks)
    if ($frameworks.Count -eq 0) { throw "No target framework was found for $Path. Supply Frameworks in its override." }
    $isTest = ConvertTo-AmithBoolean (Get-AmithValue $metadata 'IsTestProject' '')
    # On a clean checkout package-imported IsTestProject may not exist until
    # restore. Evaluated PackageReference items still identify common test SDKs.
    if (@((Get-AmithValue $metadata 'TestPackages' @()) | Where-Object { $_ -in @('Microsoft.NET.Test.Sdk','xunit.v3','MSTest.TestFramework','NUnit') }).Count) { $isTest = $true }
    $outputType = [string](Get-AmithValue $metadata 'OutputType' '')
    $usesDesktop = (ConvertTo-AmithBoolean (Get-AmithValue $metadata 'UseWPF' '')) -or
        (ConvertTo-AmithBoolean (Get-AmithValue $metadata 'UseWindowsForms' ''))
    $isDesktop = $outputType -eq 'WinExe' -or ($outputType -eq 'Exe' -and $usesDesktop)
    $packable = ConvertTo-AmithBoolean (Get-AmithValue $metadata 'IsPackable' '') ($outputType -notin @('Exe', 'WinExe'))
    $kind = if ($isTest) { 'Test' } elseif ($isDesktop) { 'Desktop' } elseif ($outputType -in @('Exe', 'WinExe')) {
        if (ConvertTo-AmithBoolean (Get-AmithValue $metadata 'UsingMicrosoftNETSdkWeb' '')) { 'Web' } else { 'Console' }
    } else { 'Library' }
    $kind = [string](Get-AmithValue $Settings 'Kind' $kind)
    if ($kind -eq 'NuGet') { throw "Kind 'NuGet' has been replaced: use Kind = 'Library' with Pack = `$true." }
    if ($kind -notin @('Test', 'Desktop', 'Web', 'Console', 'Library')) { throw "Unknown project kind '$kind' for $Path" }
    $isApplication = $kind -in @('Desktop','Web','Console')
    if ($isApplication) { $Settings = Merge-AmithMap $Settings $DeploymentOverrides }
    $name = [string](Get-AmithValue $Settings 'Name' ([IO.Path]::GetFileNameWithoutExtension($Path)))
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Project artifact name must contain only letters, digits, dots, underscores or hyphens: $name" }
    $publish = ConvertTo-AmithBoolean (Get-AmithValue $Settings 'Publish' ($kind -in @('Desktop','Web','Console')))
    $runtimes = @()
    if ($kind -in @('Desktop', 'Web', 'Console')) {
        $declared = [string](Get-AmithValue $metadata 'RuntimeIdentifiers' '')
        if (-not $declared) { $declared = [string](Get-AmithValue $metadata 'RuntimeIdentifier' '') }
        $runtimes = @(Get-AmithValue $Settings 'Runtimes' $(if ($DefaultRuntimes.Count) { $DefaultRuntimes } elseif ($declared) { $declared -split ';' } elseif ($isDesktop) { @('win-x64') } else { @('win-x64', 'linux-x64') }))
    }
    $targets = @()
    foreach ($runtime in $runtimes) {
        if ($runtime -notmatch '^[a-z0-9][a-z0-9.-]*$') { throw "Invalid runtime identifier: $runtime" }
        $compatible = @($frameworks | Where-Object { $runtime -like 'win-*' -or $_ -notmatch '-windows' })
        if ($kind -eq 'Desktop' -and $runtime -notlike 'win-*') { $compatible = @() }
        if ($compatible.Count -eq 0) { Write-Warning "${name}: omitting incompatible runtime $runtime"; continue }
        $framework = if ($runtime -like 'win-*') { @($compatible | Sort-Object { $_ -notmatch '-windows' })[0] } else { $compatible[0] }
        $targets += @{ Runtime = [string]$runtime; Framework = [string]$framework }
    }
    if ($publish -and $kind -in @('Desktop', 'Web', 'Console') -and $targets.Count -eq 0) { throw "No compatible publish target remains for $name" }
    $testPlatforms = @(Get-AmithValue $Settings 'TestPlatforms' @())
    $hostName = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'MacOS' } else { 'Linux' }
    $testFrameworks = @($frameworks | Where-Object { Test-AmithHostFramework $_ })
    if ($testPlatforms.Count -and $hostName -notin $testPlatforms) { $testFrameworks = @() }
    foreach ($pattern in @(Get-AmithValue $Settings 'PackageExcludes' @())) { Assert-AmithPackagePattern $pattern }
    return @{
        Name = $name; Path = $Path; RelativePath = [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/'); Kind = $kind
        Frameworks = $frameworks; TestFrameworks = $testFrameworks; Targets = $targets
        PackageId = [string](Get-AmithValue $metadata 'PackageId' $name)
        AssemblyName = [string](Get-AmithValue $metadata 'AssemblyName' $name)
        ProjectAssetsFile = [string](Get-AmithValue $metadata 'ProjectAssetsFile' (Join-Path (Split-Path -Parent $Path) 'obj/project.assets.json'))
        IsPackable = $packable
        Pack = $kind -eq 'Library' -and (ConvertTo-AmithBoolean (Get-AmithValue $Settings 'Pack' $false))
        Publish = $publish
        Archive = ConvertTo-AmithBoolean (Get-AmithValue $Settings 'Archive' $true)
        SelfContained = $isApplication -and (ConvertTo-AmithBoolean (Get-AmithValue $Settings 'SelfContained' $true))
        SingleFile = $isApplication -and (ConvertTo-AmithBoolean (Get-AmithValue $Settings 'SingleFile' $true))
        SelfExtract = ConvertTo-AmithBoolean (Get-AmithValue $Settings 'SelfExtract' ($kind -eq 'Desktop'))
        VersionedArchives = ConvertTo-AmithBoolean (Get-AmithValue $Settings 'VersionedArchives' $false)
        IncludeSymbols = ConvertTo-AmithBoolean (Get-AmithValue $Settings 'IncludeSymbols' $true)
        IncludeDevelopmentSettings = ConvertTo-AmithBoolean (Get-AmithValue $Settings 'IncludeDevelopmentSettings' $false)
        PackageExcludes = @(Get-AmithValue $Settings 'PackageExcludes' @())
        OriginalPublishHook = [string](Get-AmithValue $metadata 'CustomAfterMicrosoftCommonTargets' '')
        ArchiveFormats = @(Get-AmithValue $Settings 'ArchiveFormats' @())
        PublishArguments = @(Get-AmithValue $Settings 'PublishArguments' @())
        Velopack = Get-AmithValue $Settings 'Velopack' @{}
    }
}

function New-AmithBuildPlan {
    [CmdletBinding()]
    param([string] $ConfigPath, [string] $Solution, [string] $RootPath = (Get-Location).ProviderPath,
          [string] $Version, [string[]] $Runtimes = @(), [string[]] $Exclude = @(),
          [System.Collections.IDictionary[]] $Projects = @(), [Alias('Project')][string[]] $ProjectPath = @(),
          [ValidateNotNullOrEmpty()][string[]] $PackProjects = @(), [ValidateNotNullOrEmpty()][string[]] $PackOnlyProjects = @(), [ValidateNotNullOrEmpty()][string[]] $ExcludePackProjects = @(),
          [switch] $PackAllLibraries, [switch] $NoPack,
          [switch] $SelfContained, [switch] $SingleFile, [switch] $StandaloneSingleFile,
          [switch] $VersionedArchives, [switch] $UnversionedArchives,
          [switch] $IncludeSymbols, [switch] $IncludeDevelopmentSettings, [string[]] $PackageExcludes = @(),
          [switch] $NoTests, [switch] $SkipTests,
          [string] $PlanPath = '.amith-build/plan.json')
    $deploymentOverrides = Get-AmithDeploymentOverrides $PSBoundParameters
    $archiveOverrides = Get-AmithArchiveOverrides $PSBoundParameters
    $root = Resolve-AmithPath $RootPath
    $config = @{}
    $automaticConfig = -not $ConfigPath
    if ($automaticConfig) {
        # Enumerate actual entries: build/Build are one directory on a
        # case-insensitive filesystem, but may be distinct on other filesystems.
        $buildConfigs = @(Get-ChildItem -LiteralPath $root -Directory -Force |
            Where-Object { $_.Name -cin @('build','Build') } |
            ForEach-Object {
                $candidate = Join-Path $_.FullName 'amith.build.psd1'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
            })
        if ($buildConfigs.Count -gt 1) {
            throw 'Ambiguous configuration: both build/amith.build.psd1 and Build/amith.build.psd1 exist. Select one with -ConfigPath.'
        }
        if ($buildConfigs.Count -eq 1) { $ConfigPath = $buildConfigs[0] }
        elseif (Test-Path -LiteralPath (Join-Path $root 'amith.build.psd1') -PathType Leaf) { $ConfigPath = Join-Path $root 'amith.build.psd1' }
    }
    if ($ConfigPath) {
        $ConfigPath = Resolve-AmithPath $ConfigPath $root
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration file not found: $ConfigPath" }
        $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
        $configDirectory = Split-Path -Parent $ConfigPath
        if ($config.ContainsKey('Root')) { $root = Resolve-AmithPath ([string]$config.Root) $configDirectory }
        elseif (-not $automaticConfig) { $root = $configDirectory }
        Write-Host "Configuration: $ConfigPath"
    }
    $testPolicy=@{}
    foreach ($option in @('NoTests','SkipTests')) {
        $testPolicy[$option]=ConvertTo-AmithBoolean (Get-AmithValue $config $option $false)
        if ($PSBoundParameters.ContainsKey($option)) { $testPolicy[$option]=[bool]$PSBoundParameters[$option] }
    }
    $testPolicy=Get-AmithTestPolicy @{TestPolicy=$testPolicy}
    $explicitVersion = -not [string]::IsNullOrWhiteSpace($Version)
    if (-not $explicitVersion) { $Version = [string](Get-AmithValue $config 'Version' '0.0.0-local'); $explicitVersion = $config.ContainsKey('Version') }
    Assert-AmithVersion $Version
    $configuration = [string](Get-AmithValue $config 'Configuration' 'Release')
    if ($configuration -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Configuration must be a simple MSBuild configuration name.' }
    $discover = ConvertTo-AmithBoolean (Get-AmithValue $config 'Discover' $true)
    $entries = @(Get-AmithValue $config 'Projects' @()) + @($Projects)
    if ($ProjectPath.Count) {
        # A direct -Project selection means only those roots. Keep any matching
        # configured project settings, plus normal Defaults/Overrides.
        $selected = @()
        foreach ($requested in $ProjectPath) {
            $absolute = Resolve-AmithPath $requested $root
            $definition = @{ Path = $requested }
            foreach ($entry in $entries) {
                if ($entry -is [string]) { $entry = @{ Path = $entry } }
                if ((Resolve-AmithPath ([string](Get-AmithValue $entry 'Path' '')) $root) -eq $absolute) { $definition = Merge-AmithProjectSettings $definition $entry }
            }
            $selected += $definition
        }
        $entries = $selected; $discover = $false
    }
    if ($Runtimes.Count -eq 0) { $Runtimes = @(Get-AmithValue $config 'Runtimes' @()) }
    $exclusions = @(Get-AmithValue $config 'Exclude' @()) + @($Exclude)
    $definitions = @{}
    if ($discover) {
        if (-not $Solution) { $Solution = [string](Get-AmithValue $config 'Solution' '') }
        if (-not $Solution) {
            $solutions = @(Get-ChildItem -LiteralPath $root -File | Where-Object Extension -in '.sln', '.slnx')
            if ($solutions.Count -gt 1) { throw 'Multiple solutions found; specify Solution explicitly.' }
            if ($solutions.Count -eq 1) { $Solution = $solutions[0].FullName }
        }
        if ($Solution) {
            $Solution = Resolve-AmithPath $Solution $root
            foreach ($path in @(Get-AmithSolutionProjects $Solution)) { $definitions[$path] = @{} }
        } elseif ($entries.Count -eq 0) {
            $single = @(Get-ChildItem -LiteralPath $root -File | Where-Object Extension -in '.csproj', '.fsproj', '.vbproj')
            if ($single.Count -ne 1) { throw 'Specify Solution or Projects; no single root solution/project was found.' }
            $definitions[$single[0].FullName] = @{}
        }
    }
    foreach ($entry in $entries) {
        if ($entry -is [string]) { $entry = @{ Path = $entry } }
        $path = Resolve-AmithPath ([string](Get-AmithValue $entry 'Path' '')) $root
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Configured project does not exist: $path" }
        $definitions[$path] = Merge-AmithProjectSettings (Get-AmithValue $definitions $path @{}) $entry
    }
    $planned = @()
    foreach ($path in @($definitions.Keys | Sort-Object)) {
        $relative = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/')
        if (@($exclusions | Where-Object { Test-AmithPattern $relative $_ }).Count) { continue }
        $settings = Merge-AmithProjectSettings (Get-AmithValue $config 'Defaults' @{}) $definitions[$path]
        foreach ($override in @(Get-AmithValue $config 'Overrides' @())) {
            $pattern = [string](Get-AmithValue $override 'Match' '')
            if (-not $pattern) { throw 'Each Overrides entry needs Match.' }
            if (Test-AmithPattern $relative $pattern) { $settings = Merge-AmithProjectSettings $settings $override }
        }
        if (ConvertTo-AmithBoolean (Get-AmithValue $settings 'Exclude' $false)) { continue }
        $settings = Merge-AmithMap $settings $archiveOverrides
        foreach ($option in @('IncludeSymbols','IncludeDevelopmentSettings')) {
            if ($PSBoundParameters.ContainsKey($option)) { $settings[$option] = [bool]$PSBoundParameters[$option] }
        }
        $settings.PackageExcludes = @(Get-AmithValue $settings 'PackageExcludes' @()) + $PackageExcludes
        $planned += Get-AmithProjectPlan $path $settings $root $configuration $Runtimes $Version $deploymentOverrides
    }
    Assert-AmithNoTestsDeclaration $planned $testPolicy
    if ($planned.Count -eq 0) { throw 'No projects remain in the build plan.' }
    $duplicates = @($planned | Group-Object Name | Where-Object Count -gt 1)
    if ($duplicates.Count) { throw 'Duplicate artifact names; supply unique Name overrides for those projects.' }
    Set-AmithPackSelection -Projects $planned -PackProjects $PackProjects -PackOnlyProjects $PackOnlyProjects `
        -ExcludePackProjects $ExcludePackProjects -PackAllLibraries:$PackAllLibraries -NoPack:$NoPack
    $runId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $outputBase = Resolve-AmithPath ([string](Get-AmithValue $config 'Output' 'artifacts')) $root
    $outputRoot = Join-Path (Join-Path $outputBase $Version) $runId
    $plan = @{
        SchemaVersion = $script:AmithPlanSchemaVersion; Root = $root; Solution = $Solution; Version = $Version; ExplicitVersion = $explicitVersion; SourceCommit = Get-AmithSourceCommit $root
        Configuration = $configuration; RunId = $runId; OutputRoot = $outputRoot; OutputBase = $outputBase; Projects = @($planned)
        TestPolicy = $testPolicy
        Artifacts = @(); Stages = @{}; Release = Get-AmithValue $config 'Release' @{}
        PlanPath = Resolve-AmithPath $PlanPath $root
    }
    Write-AmithJson $plan $plan.PlanPath
    Write-Host "Build plan: $($plan.PlanPath)"
    Write-Host ("Test policy: " + $(if ($testPolicy.NoTests) {'NoTests'} elseif ($testPolicy.SkipTests) {'SkipTests'} else {'Required'}))
    foreach ($project in $planned) { Write-Host ("  {0}: {1} [{2}]{3}" -f $project.Name, $project.Kind, (($project.Targets | ForEach-Object Runtime) -join ', '), $(if ($project.Pack) { ' Pack=true' } else { '' })) }
    return $plan
}

function Set-AmithPackSelection {
    param([object[]] $Projects, [string[]] $PackProjects = @(), [string[]] $PackOnlyProjects = @(),
          [string[]] $ExcludePackProjects = @(), [switch] $PackAllLibraries, [switch] $NoPack)
    if ($NoPack -and ($PackProjects.Count -or $PackOnlyProjects.Count -or $ExcludePackProjects.Count -or $PackAllLibraries)) {
        throw 'NoPack cannot be combined with packaging selection options.'
    }
    if ($PackOnlyProjects.Count -and ($PackProjects.Count -or $PackAllLibraries)) {
        throw 'PackOnlyProjects cannot be combined with PackProjects or PackAllLibraries.'
    }
    $byName = @{}
    foreach ($project in $Projects) { $byName[$project.Name] = $project }
    foreach ($name in @($PackProjects) + @($PackOnlyProjects) + @($ExcludePackProjects)) {
        if ([string]::IsNullOrWhiteSpace($name) -or -not $byName.ContainsKey($name)) {
            throw "Unknown packaging project '$name'. Use exact project names from the plan (no patterns)."
        }
        if ($byName[$name].Kind -ne 'Library') { throw "Packaging project '$name' is not a library." }
    }
    foreach ($project in $Projects) {
        if ($NoPack -or $PackOnlyProjects.Count) { $project.Pack = $false }
        elseif ($PackAllLibraries) { $project.Pack = $project.Kind -eq 'Library' -and $project.IsPackable }
    }
    foreach ($name in @($PackProjects) + @($PackOnlyProjects)) { $byName[$name].Pack = $true }
    foreach ($name in $ExcludePackProjects) { $byName[$name].Pack = $false }
    foreach ($project in $Projects) {
        if ($project.Pack -and -not $project.IsPackable) {
            throw "Cannot package '$($project.Name)': the project evaluates IsPackable=false. Exclude it from packaging or change the project setting."
        }
    }
}

function Get-AmithDeploymentOverrides {
    param([System.Collections.IDictionary] $Options)
    $overrides = @{}
    if ($Options.ContainsKey('StandaloneSingleFile')) {
        if (-not $Options.StandaloneSingleFile) { throw 'StandaloneSingleFile is enable-only. To disable settings use SelfContained:$false and/or SingleFile:$false.' }
        if ($Options.ContainsKey('SelfContained') -or $Options.ContainsKey('SingleFile')) {
            throw 'StandaloneSingleFile cannot be combined with SelfContained or SingleFile. Use the individual options for precise control.'
        }
        return @{ SelfContained = $true; SingleFile = $true }
    }
    foreach ($option in @('SelfContained','SingleFile')) {
        if ($Options.ContainsKey($option)) { $overrides[$option] = [bool]$Options[$option] }
    }
    return $overrides
}

function Get-AmithArchiveOverrides {
    param([System.Collections.IDictionary] $Options)
    if ($Options.ContainsKey('UnversionedArchives')) {
        if (-not $Options.UnversionedArchives) {
            throw 'UnversionedArchives is enable-only. Use VersionedArchives to include the version.'
        }
        if ($Options.ContainsKey('VersionedArchives')) {
            throw 'VersionedArchives and UnversionedArchives cannot be combined. Use one archive naming option.'
        }
        return @{ VersionedArchives = $false }
    }
    if ($Options.ContainsKey('VersionedArchives')) { return @{ VersionedArchives = [bool]$Options.VersionedArchives } }
    return @{}
}
