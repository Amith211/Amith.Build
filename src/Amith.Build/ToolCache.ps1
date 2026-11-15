# Shared by local builds and CI. Tool contents never belong in retained build artifacts.
function Get-AmithToolCacheRoot {
    $root = $env:AMITH_TOOL_CACHE
    if (-not $root) { $root = $env:RUNNER_TOOL_CACHE }
    if (-not $root) {
        $root = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.cache/amith-build/tools'
    }
    return [IO.Path]::GetFullPath($root)
}

function Install-AmithCachedVelopack {
    param([string]$Version, $Plan)
    $platform = if ($IsWindows) { 'win32' } elseif ($IsLinux) { 'linux' } else { throw 'Velopack cache supports Windows and Linux hosts.' }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    Assert-AmithVersion $Version
    $cacheRoot = [IO.Path]::GetFullPath((Get-AmithToolCacheRoot))
    $directory = [IO.Path]::GetFullPath((Join-Path $cacheRoot "amith-build/vpk/$Version/$platform-$architecture"))
    $prefix = $cacheRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $directory.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Velopack cache path escapes the configured tool cache root.' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $directory))
    $lockPath = "$directory.lock"
    $lock = $null
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    while (-not $lock) {
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for Velopack cache lock: $lockPath" }
            Start-Sleep -Milliseconds 500
        }
    }
    try {
        $executable = Join-Path $directory $(if ($IsWindows) { 'vpk.exe' } else { 'vpk' })
        $marker = Join-Path $directory '.amith-ready.json'
        $ready = $false
        if ((Test-Path -LiteralPath $marker -PathType Leaf) -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
            try {
                $receipt = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -AsHashtable
                $ready = $receipt.Version -ceq $Version -and $receipt.Sha256 -ceq (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
            } catch { $ready = $false }
        }
        if ($ready) {
            Write-Host "Cache hit: vpk $Version ($platform-$architecture)"
            # Verify the shim and its runtime/dependencies are usable, including cache hits.
            $null = Invoke-AmithNative $executable @('--skip-updates','--help') $Plan.Root -Capture
            return $executable
        }
        # .NET tool shims may bind to their installation path, so install in place
        # under an exclusive lock and only mark ready after successful validation.
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        try {
            $arguments = @('tool','install','vpk','--version',$Version,'--tool-path',$directory)
            $sdk = (@(Invoke-AmithNative dotnet @('--version') $Plan.Root -Capture) -join '').Trim()
            if ([int]($sdk -split '\.')[0] -ge 9) { $arguments += '--allow-roll-forward' }
            Invoke-AmithNative dotnet $arguments $Plan.Root
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'The selected vpk tool was not installed successfully.' }
            $null = Invoke-AmithNative $executable @('--skip-updates','--help') $Plan.Root -Capture
            @{Version=$Version;Sha256=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash} |
                ConvertTo-Json | Set-Content -LiteralPath $marker
            Write-Host "Cached tool: vpk $Version ($platform-$architecture)"
        } catch {
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
            throw
        }
        return $executable
    } finally { $lock.Dispose() }
}
