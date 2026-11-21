$script:AmithDotnetPath = ''
$script:AmithSdkWorkingDirectory = ''
# Schema identifiers are independent of module/action release versions.
# Compatible optional additions keep this identifier and preserve existing defaults.
# Incompatible format/semantic changes or maturity transitions require a new identifier.
$script:AmithPlanSchemaVersion = '1alpha1'

function Invoke-AmithTimed {
    param([string]$Label,[scriptblock]$Operation)
    $timingWatch=[Diagnostics.Stopwatch]::StartNew()
    $timingCompleted=$false
    Write-Host ("[timing] {0} START {1}" -f [DateTime]::UtcNow.ToString('o'),$Label)
    try {
        & $Operation
        $timingCompleted=$true
    } finally {
        $timingWatch.Stop()
        $timingStatus=if($timingCompleted){'DONE'}else{'FAILED'}
        Write-Host ("[timing] {0} {1} {2} ({3:F3}s)" -f [DateTime]::UtcNow.ToString('o'),$timingStatus,$Label,$timingWatch.Elapsed.TotalSeconds)
    }
}

function Get-AmithValue {
    param($Map, [string] $Name, $Default = $null)
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) { if ([string]$key -ieq $Name) { return $Map[$key] } }
    }
    return $Default
}

function Merge-AmithMap {
    param($Base, $Override)
    $result = @{}
    foreach ($map in @($Base, $Override)) {
        if ($map -isnot [System.Collections.IDictionary]) { continue }
        foreach ($key in $map.Keys) {
            if ($result.ContainsKey($key) -and $result[$key] -is [System.Collections.IDictionary] -and $map[$key] -is [System.Collections.IDictionary]) {
                $result[$key] = Merge-AmithMap $result[$key] $map[$key]
            } else { $result[$key] = $map[$key] }
        }
    }
    return $result
}

function ConvertTo-AmithBoolean {
    param($Value, [bool] $Default = $false)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    if ($Value -is [bool]) { return $Value }
    switch ([string]$Value) {
        'true' { return $true }; 'false' { return $false }; '1' { return $true }; '0' { return $false }
        default { throw "Invalid Boolean setting: $Value" }
    }
}

function Resolve-AmithPath {
    param([string] $Path, [string] $Base = (Get-Location).ProviderPath)
    $nativePath = $Path.Replace('\', [IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::IsPathFullyQualified($nativePath)) { return [IO.Path]::GetFullPath($nativePath) }
    return [IO.Path]::GetFullPath((Join-Path $Base $nativePath))
}

function Test-AmithPattern {
    param([string] $Path, [string] $Pattern)
    $pathText = $Path.Replace('\', '/') -replace '^\./', ''
    $patternText = $Pattern.Replace('\', '/') -replace '^\./', ''
    $regex = [regex]::Escape($patternText).Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
    if ($pathText -imatch "^$regex`$") { return $true }
    if (-not $patternText.Contains('/')) {
        return [IO.Path]::GetFileNameWithoutExtension($pathText) -ilike $patternText -or [IO.Path]::GetFileName($pathText) -ilike $patternText
    }
    return $false
}

function Invoke-AmithNative {
    param([string] $File, [string[]] $Arguments = @(), [string] $WorkingDirectory, [switch] $Capture, [string[]] $SensitiveValues = @())
    if ($File -eq 'dotnet' -and $script:AmithDotnetPath) {
        $File = $script:AmithDotnetPath
        if (-not $WorkingDirectory) { $WorkingDirectory = $script:AmithSdkWorkingDirectory }
    }
    $PSNativeCommandUseErrorActionPreference = $false
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        $lines = @(& $File @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $safeLines = @($lines | ForEach-Object {
            $text = [string]$_
            foreach ($secret in $SensitiveValues) { if (-not [string]::IsNullOrEmpty($secret)) { $text = $text.Replace($secret, '***') } }
            $text
        })
        if (-not $Capture -or $exitCode -ne 0) { foreach ($line in $safeLines) { Write-Host $line } }
        if ($exitCode -ne 0) { throw "$File failed with exit code $exitCode. The stage has stopped." }
        if ($Capture) { return $safeLines }
    }
    finally { if ($WorkingDirectory) { Pop-Location } }
}

function Assert-AmithVersion {
    param([string] $Version)
    $parsed = $null
    if (-not [System.Management.Automation.SemanticVersion]::TryParse($Version, [ref]$parsed) -or
        $Version -cne $parsed.ToString() -or $Version.Contains('+')) {
        throw 'Version must be canonical SemVer such as 1.2.3 or 1.2.3-rc.1, without a v prefix or build metadata.'
    }
}

function Write-AmithJson {
    param($Value, [string] $Path)
    $parent = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($parent)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 60), [Text.UTF8Encoding]::new($false))
}

function Read-AmithPlan {
    param([string] $Path)
    $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 60
    $schemaVersion = Get-AmithValue $plan 'SchemaVersion' $null
    if ($schemaVersion -isnot [string] -or $schemaVersion -cne $script:AmithPlanSchemaVersion) {
        throw "Unsupported build-plan schema '$schemaVersion'; expected '$script:AmithPlanSchemaVersion'. Regenerate the plan."
    }
    return $plan
}

function Assert-AmithOutputPath {
    param($Plan, [string] $Path)
    $root = [IO.Path]::GetFullPath($Plan.OutputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($root, $comparison)) { throw 'Artifact path escaped the build output directory.' }
    return $full
}

function Add-AmithArtifact {
    param($Plan, [string] $Kind, $Project, [string] $Path, [string] $Runtime = '')
    $full = Assert-AmithOutputPath $Plan $Path
    if (-not (Test-Path -LiteralPath $full)) { throw "Expected artifact was not produced: $full" }
    $hash = if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } else { '' }
    $Plan.Artifacts = @($Plan.Artifacts | Where-Object { $_.Path -ne $full }) + @(@{
        Kind = $Kind; Project = $Project.Name; Runtime = $Runtime; Path = $full; Version = $Plan.Version; SHA256 = $hash
    })
}

function Get-AmithBuildArguments {
    param($Plan)
    return @('--configuration', $Plan.Configuration, "-p:Version=$($Plan.Version)", '-p:EnableWindowsTargeting=true', '-p:ContinuousIntegrationBuild=true')
}

function Test-AmithHostFramework {
    param([string] $Framework)
    if ($IsWindows) { return $true }
    return $Framework -notmatch '-windows' -and $Framework -notmatch '^net[1-4][0-9]{1,2}$'
}

function Get-AmithSourceCommit {
    param([string] $Root)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return '' }
    # Optional read-only Git metadata must not alter LASTEXITCODE or emit fatal
    # errors for a new/non-Git local workspace.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $git.Source
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $Root, 'rev-parse', '--verify', 'HEAD')) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEnd()
        [void]$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -eq 0) { return $output.Trim() }
        return ''
    }
    finally { $process.Dispose() }
}
