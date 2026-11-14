function Merge-AmithProjectSettings {
    param($Base, $Override)
    $result = Merge-AmithMap $Base $Override
    $result.PackageExcludes = @(Get-AmithValue $Base 'PackageExcludes' @()) + @(Get-AmithValue $Override 'PackageExcludes' @())
    return $result
}

function Assert-AmithPackagePattern {
    param([string] $Pattern)
    $patternPath = $Pattern.Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($patternPath) -or $patternPath.StartsWith('/') -or $patternPath -match '^[A-Za-z]:' -or $patternPath -match '(^|/)\.\.(/|$)') {
        throw "PackageExcludes requires a nonempty relative glob without parent traversal: $Pattern"
    }
}

function Test-AmithPackagePattern {
    param([string] $RelativePath, [string] $Pattern)
    $patternPath = $Pattern.Replace('\','/') -replace '^\./',''
    $regex = [regex]::Escape($patternPath).Replace('\*\*/','(?:.*/)?').Replace('\*\*','.*').Replace('\*','[^/]*').Replace('\?','[^/]')
    return [regex]::IsMatch($RelativePath.Replace('\','/'), '^'+$regex+'$', [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-AmithPackageInventory {
    param([string] $Directory)
    if ((Get-Item -LiteralPath $Directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Publish output contains a symbolic link or junction. Publish the actual file content before packaging; links are not followed.'
    }
    $directories = [Collections.Generic.Stack[string]]::new(); $directories.Push($Directory)
    $files = @()
    while ($directories.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $directories.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Publish output contains a symbolic link or junction. Publish the actual file content before packaging; links are not followed.'
            }
            if ($item.PSIsContainer) { $directories.Push($item.FullName); continue }
            $files += [ordered]@{Path=[IO.Path]::GetRelativePath($Directory,$item.FullName).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash;Size=$item.Length}
        }
    }
    return @($files | Sort-Object Path -CaseSensitive)
}

function Get-AmithPackageInput {
    param($Plan, $Project, $Artifact)
    $includeSymbols = ConvertTo-AmithBoolean (Get-AmithValue $Project 'IncludeSymbols' $true)
    $includeDevelopment = ConvertTo-AmithBoolean (Get-AmithValue $Project 'IncludeDevelopmentSettings' $false)
    $patterns = @(Get-AmithValue $Project 'PackageExcludes' @())
    foreach ($pattern in $patterns) { Assert-AmithPackagePattern $pattern }
    $policy = ConvertTo-Json -InputObject @($includeSymbols,$includeDevelopment,$patterns) -Depth 5 -Compress
    $source = Assert-AmithOutputPath $Plan $Artifact.Path
    $inventory = @(Get-AmithPackageInventory $source)
    $sourceState = ConvertTo-Json -InputObject $inventory -Depth 5 -Compress
    if (-not $Plan.Contains('PackageInputs')) { $Plan.PackageInputs = @{} }
    $key = "$($Project.Name)|$($Artifact.Runtime)"
    $existing = Get-AmithValue $Plan.PackageInputs $key @{}
    if ($existing.Count) {
        if ($existing.Source -ne $source -or $existing.Policy -cne $policy -or $existing.SourceState -cne $sourceState) {
            throw 'Publish output or packaging settings changed after package preparation. Create a fresh plan instead of mixing package inputs.'
        }
        $preparedDirectory = Assert-AmithOutputPath $Plan $existing.Directory
        $prepared = @(Get-AmithPackageInventory $preparedDirectory)
        $expected = @($existing.Files | Where-Object Included | ForEach-Object { [ordered]@{Path=$_.Path;SHA256=$_.SHA256;Size=$_.Size} })
        if ((ConvertTo-Json -InputObject $prepared -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $expected -Depth 5 -Compress)) {
            throw 'Prepared package files changed or are missing. Create a fresh plan.'
        }
        return $existing
    }
    $directory = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "package-inputs/$($Project.Name)/$($Artifact.Runtime)/$([guid]::NewGuid().ToString('N'))")
    [void][IO.Directory]::CreateDirectory($directory)
    $records = @()
    foreach ($file in $inventory) {
        $reason = ''
        if (-not $includeDevelopment -and $file.Path -imatch '(^|/)([^/]*\.Development\.json|Development\.json)$') { $reason = 'Development settings excluded' }
        elseif (-not $includeSymbols -and $file.Path.EndsWith('.pdb',[StringComparison]::OrdinalIgnoreCase)) { $reason = 'Symbols disabled' }
        foreach ($pattern in $patterns) {
            if (Test-AmithPackagePattern $file.Path $pattern) { $reason = "PackageExcludes: $pattern"; break }
        }
        $record = @{Path=$file.Path;SHA256=$file.SHA256;Size=$file.Size;Included=($reason -eq '');Reason=$reason}
        $records += $record
        if ($record.Included) {
            $destination = Assert-AmithOutputPath @{OutputRoot=$directory} (Join-Path $directory $file.Path)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $source $file.Path) -Destination $destination
            if (-not $IsWindows) { [IO.File]::SetUnixFileMode($destination,[IO.File]::GetUnixFileMode((Join-Path $source $file.Path))) }
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $file.SHA256) { throw 'Publish file changed while preparing the package. Create a fresh plan.' }
        }
    }
    $snapshot = @{Directory=$directory;Source=$source;Policy=$policy;SourceState=$sourceState;Files=$records}
    $Plan.PackageInputs[$key] = $snapshot
    $included = @($records | Where-Object Included).Count
    Write-Host "Prepared $($Project.Name) [$($Artifact.Runtime)]: $included files included, $($records.Count-$included) excluded."
    foreach ($file in @($records | Where-Object { -not $_.Included })) { Write-Host "  $($file.Path) - $($file.Reason)" }
    return $snapshot
}

function Invoke-AmithRetain {
    param($Plan)
    [void]$Plan.Remove('RetainedRoot')
    $selected = @($Plan.Artifacts | Where-Object Kind -in @('Archive','Installer','NuGet','Symbols'))
    $root = Assert-AmithOutputPath $Plan (Join-Path $Plan.OutputRoot "retained/$([guid]::NewGuid().ToString('N'))")
    [void][IO.Directory]::CreateDirectory($root)
    foreach ($file in $selected) {
        $producer = switch ($file.Kind) {Archive {'Archive'};Installer {'Installer'};default {'Pack'}}
        Assert-AmithStage $Plan $producer
        $path = Assert-AmithOutputPath $Plan $file.Path
        if (-not $file.SHA256 -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.SHA256) {
            throw 'A selected retention artifact is missing or changed. Recreate the artifacts.'
        }
        $relative = [IO.Path]::GetRelativePath($Plan.OutputRoot,$path)
        $destination = Assert-AmithOutputPath @{OutputRoot=$root} (Join-Path $root $relative)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $path -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $file.SHA256) { throw 'Artifact changed while preparing retention output.' }
    }
    $Plan.RetainedRoot = $root
    Write-Host "Prepared $($selected.Count) recorded artifacts for CI retention."
}
