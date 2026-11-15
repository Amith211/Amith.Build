function Invoke-AmithBuildStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PlanPath,
          [Parameter(Mandatory)][ValidateSet('Restore','Build','Test','Pack','Publish','Archive','Installer','Retain','Release')][string] $Stage)
    $PlanPath = Resolve-AmithPath $PlanPath
    $plan = Read-AmithPlan $PlanPath
    $Stage = @('Restore','Build','Test','Pack','Publish','Archive','Installer','Retain','Release') | Where-Object { $_ -ieq $Stage }
    if ($Stage -in @('Restore', 'Build')) {
        # A rebuild invalidates prior artifact gates. Files are retained, but are
        # no longer eligible for release through this manifest.
        [void]$plan.Remove('TestResults')
        $plan.Artifacts = @()
        [void]$plan.Remove('VelopackPackages')
        [void]$plan.Remove('PackageInputs')
        [void]$plan.Remove('RetainedRoot')
        foreach ($dependent in @('Test','Pack','Publish','Archive','Installer','Retain','Release')) { [void]$plan.Stages.Remove($dependent) }
        if ($Stage -eq 'Restore') { [void]$plan.Stages.Remove('Build') }
    }
    if ($Stage -eq 'Test') { [void]$plan.Stages.Remove('Release') }
    if ($Stage -in @('Pack','Publish','Archive','Installer')) {
        [void]$plan.Remove('RetainedRoot')
        [void]$plan.Stages.Remove('Retain')
    }
    $plan.Stages[$Stage] = @{ Status = 'Running'; StartedUtc = [DateTime]::UtcNow.ToString('o') }
    Write-AmithJson $plan $PlanPath
    $sdkScope = $null
    try {
        if (Get-AmithValue $plan 'SdkExecution' $null) { $sdkScope = Open-AmithSdkScope -RootPath $plan.Root -Execution $plan.SdkExecution }
        Write-Host "Amith.Build: $Stage ($($plan.Version))"
        switch ($Stage) {
            Restore { Invoke-AmithRestore $plan }
            Build { Invoke-AmithCompile $plan }
            Test { Invoke-AmithTests $plan }
            Pack { Invoke-AmithPack $plan }
            Publish { Invoke-AmithPublish $plan }
            Archive { Invoke-AmithArchive $plan }
            Installer { Invoke-AmithInstaller $plan }
            Retain { Invoke-AmithRetain $plan }
            Release { Invoke-AmithRelease $plan }
        }
        $plan.Stages[$Stage].Status = 'Succeeded'
    }
    catch {
        $plan.Stages[$Stage].Status = 'Failed'
        throw
    }
    finally {
        if ($sdkScope) { Close-AmithSdkScope $sdkScope }
        $plan.Stages[$Stage].FinishedUtc = [DateTime]::UtcNow.ToString('o')
        Write-AmithJson $plan $PlanPath
    }
    return $plan
}

function Invoke-AmithBuild {
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
          [string] $SdkVersion, [string[]] $AdditionalSdks = @(),
          [string] $PlanPath,
          [ValidateSet('Plan','Restore','Build','Test','Pack','Publish','Archive','Installer','Retain','Release')]
          [string[]] $Stages = @('Restore','Build','Test','Pack','Publish','Archive','Installer'), [switch] $PlanOnly)
    $reusePlan = $PSBoundParameters.ContainsKey('PlanPath') -and -not $ConfigPath -and -not $Solution -and
        -not $Version -and -not $PSBoundParameters.ContainsKey('RootPath') -and $Projects.Count -eq 0 -and $ProjectPath.Count -eq 0 -and
        $Runtimes.Count -eq 0 -and $Exclude.Count -eq 0 -and $PackProjects.Count -eq 0 -and $PackOnlyProjects.Count -eq 0 -and
        $ExcludePackProjects.Count -eq 0 -and -not $PackAllLibraries -and -not $NoPack -and
        -not $PSBoundParameters.ContainsKey('SelfContained') -and -not $PSBoundParameters.ContainsKey('SingleFile') -and
        -not $PSBoundParameters.ContainsKey('StandaloneSingleFile') -and
        -not $PSBoundParameters.ContainsKey('VersionedArchives') -and -not $PSBoundParameters.ContainsKey('UnversionedArchives') -and
        -not $PSBoundParameters.ContainsKey('IncludeSymbols') -and -not $PSBoundParameters.ContainsKey('IncludeDevelopmentSettings') -and
        -not $PSBoundParameters.ContainsKey('NoTests') -and -not $PSBoundParameters.ContainsKey('SkipTests') -and
        -not $PSBoundParameters.ContainsKey('SdkVersion') -and $AdditionalSdks.Count -eq 0 -and
        $PackageExcludes.Count -eq 0 -and (Test-Path -LiteralPath (Resolve-AmithPath $PlanPath))
    if ($reusePlan) { $plan = Read-AmithPlan (Resolve-AmithPath $PlanPath) }
    else {
        $arguments = @{ RootPath = $RootPath; Runtimes = $Runtimes; Exclude = $Exclude; Projects = $Projects; ProjectPath = $ProjectPath
            PackAllLibraries = $PackAllLibraries; NoPack = $NoPack }
        foreach ($option in @('SelfContained','SingleFile','StandaloneSingleFile','VersionedArchives','UnversionedArchives','IncludeSymbols','IncludeDevelopmentSettings','NoTests','SkipTests')) {
            if ($PSBoundParameters.ContainsKey($option)) { $arguments[$option] = $PSBoundParameters[$option] }
        }
        if ($PSBoundParameters.ContainsKey('SdkVersion')) { $arguments.SdkVersion = $SdkVersion }
        if ($AdditionalSdks.Count) { $arguments.AdditionalSdks = $AdditionalSdks }
        if ($PackageExcludes.Count) { $arguments.PackageExcludes = $PackageExcludes }
        if ($PackProjects.Count) { $arguments.PackProjects = $PackProjects }
        if ($PackOnlyProjects.Count) { $arguments.PackOnlyProjects = $PackOnlyProjects }
        if ($ExcludePackProjects.Count) { $arguments.ExcludePackProjects = $ExcludePackProjects }
        if ($ConfigPath) { $arguments.ConfigPath = $ConfigPath }; if ($Solution) { $arguments.Solution = $Solution }
        if ($Version) { $arguments.Version = $Version }; if ($PlanPath) { $arguments.PlanPath = $PlanPath }
        $plan = New-AmithBuildPlan @arguments
    }
    if ($PlanOnly) { return $plan }
    foreach ($stage in $Stages) {
        if ($stage -ieq 'Plan') { continue }
        $plan = Invoke-AmithBuildStage -PlanPath $plan.PlanPath -Stage $stage
    }
    return $plan
}
