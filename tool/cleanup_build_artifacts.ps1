param(
    [string]$RepoRoot
)

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$reclaimed = 0

$flutterBuild = Join-Path $RepoRoot '.dart_tool\flutter_build'
if (Test-Path $flutterBuild) {
    $hashDirs = Get-ChildItem $flutterBuild -Directory |
        Where-Object { $_.Name -match '^[0-9a-f]{32}$' }
    if ($hashDirs.Count -gt 1) {
        $latest = $hashDirs |
            Sort-Object { (Get-Item (Join-Path $_.FullName '.filecache')).LastWriteTime } -Descending |
            Select-Object -First 1
        $old = $hashDirs | Where-Object { $_.FullName -ne $latest.FullName }
        foreach ($d in $old) {
            $size = (Get-ChildItem $d.FullName -Recurse -File | Measure-Object Length -Sum).Sum
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
            $reclaimed += $size
        }
    }
}

$hooksRunner = Join-Path $RepoRoot '.dart_tool\hooks_runner'
if (Test-Path $hooksRunner) {
    $pluginNames = @(
        'ffmpeg_kit_extended_flutter',
        'objective_c',
        'sqlite3'
    )
    foreach ($plugin in $pluginNames) {
        $pluginPath = Join-Path $hooksRunner $plugin
        if (Test-Path $pluginPath) {
            $versionDirs = Get-ChildItem $pluginPath -Directory |
                Where-Object { $_.Name -match '^[0-9a-f]{10}$' }
            if ($versionDirs.Count -gt 1) {
                $latestV = $versionDirs | Sort-Object CreationTime -Descending | Select-Object -First 1
                $oldV = $versionDirs | Where-Object { $_.FullName -ne $latestV.FullName }
                foreach ($d in $oldV) {
                    $size = (Get-ChildItem $d.FullName -Recurse -File | Measure-Object Length -Sum).Sum
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force
                    $reclaimed += $size
                }
            }
        }

        $sharedBuildPath = Join-Path $hooksRunner "shared\$plugin\build"
        if (Test-Path $sharedBuildPath) {
            $versionDirs = Get-ChildItem $sharedBuildPath -Directory |
                Where-Object { $_.Name -match '^[0-9a-f]{10}$' }
            if ($versionDirs.Count -gt 1) {
                $latestV = $versionDirs | Sort-Object CreationTime -Descending | Select-Object -First 1
                $oldV = $versionDirs | Where-Object { $_.FullName -ne $latestV.FullName }
                foreach ($d in $oldV) {
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force
                }
            }
        }
    }
}

$testCache = Join-Path $RepoRoot 'build\test_cache'
if (Test-Path $testCache) {
    $size = (Get-ChildItem $testCache -Recurse -File | Measure-Object Length -Sum).Sum
    if ($size -gt 0) {
        Remove-Item -LiteralPath $testCache -Recurse -Force
        New-Item -ItemType Directory -Path $testCache | Out-Null
        $reclaimed += $size
    }
}

if ($reclaimed -gt 0) {
    Write-Host "Cleaned $([math]::Round($reclaimed / 1MB, 2)) MB of stale build artifacts."
} else {
    Write-Host "No stale build artifacts to clean."
}