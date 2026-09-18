[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('WindowsX64')]
    [string] $Target,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration,
    [switch] $FullRegression,
    [switch] $SkipQuality,
    [switch] $SkipInstaller,
    [switch] $DedicatedBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$flutterw = Join-Path $PSScriptRoot 'flutterw.ps1'
. (Join-Path $PSScriptRoot 'build_resource_guard.ps1')

if ($FullRegression.IsPresent -eq $SkipQuality.IsPresent) {
    throw 'Choose exactly one quality mode: -FullRegression or -SkipQuality.'
}

$configurationLower = $Configuration.ToLowerInvariant()
$configurationDirectory = if ($Configuration -eq 'Release') { 'Release' } else { 'Debug' }
$versionLine = Select-String -Path (Join-Path $repoRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml version was not found.' }
$repositoryFullVersion = $versionLine.Matches[0].Groups[1].Value
$fullVersion = $repositoryFullVersion
$displayVersion = $fullVersion.Split('+')[0]
$buildNumber = if ($fullVersion.Contains('+')) { $fullVersion.Split('+')[1] } else { '1' }
if ($Target -eq 'WindowsX64') {
    # Maintained platforms can intentionally be released at different
    # versions. Always build Windows from its platform feed entry rather than
    # silently stamping the newer Android/pubspec version onto the EXE.
    $versionFeedPath = Join-Path $repoRoot 'assets\version.json'
    $versionFeed = Get-Content -LiteralPath $versionFeedPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $versionFeed.platforms.windows.version -or -not $versionFeed.platforms.windows.build_number) {
        throw 'assets/version.json is missing the Windows platform version.'
    }
    $displayVersion = [string]$versionFeed.platforms.windows.version
    $buildNumber = [string]$versionFeed.platforms.windows.build_number
    $fullVersion = "$displayVersion+$buildNumber"
}
$artifactVersion = $fullVersion.Replace('+', '-')
$output = Join-Path $repoRoot "local-artifacts\$artifactVersion"
$recordDirectory = Join-Path $repoRoot 'local-artifacts\build-records'
New-Item -ItemType Directory -Force -Path $output, $recordDirectory | Out-Null

$lease = $null
$monitor = $null
$resourceSummary = $null
$remainingHeavyProcesses = $null
$startedAt = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$status = 'failed'
$failureMessage = $null
$artifactPaths = @()
$packageMetadata = $null
$commandLog = Join-Path $recordDirectory "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$($Target.ToLowerInvariant())-$configurationLower.log"
Set-Content -LiteralPath $commandLog -Value '' -Encoding utf8
$incrementalStateBefore = Test-Path -LiteralPath (Join-Path $repoRoot 'build\windows\x64')

function Assert-PureLiveCommandSucceeded {
    param(
        [Parameter(Mandatory = $true)][string] $Label,
        [Parameter(Mandatory = $true)][int] $ExitCode
    )
    if ($ExitCode -ne 0) { throw "$Label exited with code $ExitCode." }
}

function Invoke-PureLiveLoggedFlutter {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    # A native warning written to stderr is diagnostic output, not a PowerShell
    # failure. Keep it visible and logged, then decide success from LASTEXITCODE.
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $previousNativeCommandPreference = if ($nativePreferenceVariable) {
        $PSNativeCommandUseErrorActionPreference
    } else {
        $null
    }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceVariable) { $PSNativeCommandUseErrorActionPreference = $false }
        & $flutterw @Arguments 2>&1 | Tee-Object -FilePath $LogPath | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        if ($nativePreferenceVariable) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
        }
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return $exitCode
}

Push-Location $repoRoot
try {
    if ($FullRegression) {
        & (Join-Path $PSScriptRoot 'local_ci.ps1') -Scope Full -TestConcurrency 12
    }

    $taskName = "build-$($Target.ToLowerInvariant())-$configurationLower"
    $lease = Enter-PureLiveHeavyTaskSlot -TaskName $taskName
    $monitor = Start-PureLiveResourceMonitor

    $pubGetExitCode = Invoke-PureLiveLoggedFlutter `
        -Arguments @('pub', 'get', '--enforce-lockfile') `
        -LogPath $commandLog
    Assert-PureLiveCommandSucceeded 'Windows locked dependency resolution' -ExitCode $pubGetExitCode

    $windowsArgs = @(
            'build', 'windows', "--$configurationLower",
            "--build-name=$displayVersion", "--build-number=$buildNumber",
            # The locked pub stage above has already generated the Windows
            # plugin links from the physical repository path. Re-running pub
            # while Flutter is using the short junction can delete that tree
            # and then fail to recreate `.plugin_symlinks` through the
            # reparse point. Keep dependency resolution single-owner.
            '--no-pub',
            '--dart-define=PURELIVE_BUILD_SOURCE=local'
        )
        $buildExitCode = Invoke-PureLiveLoggedFlutter -Arguments $windowsArgs -LogPath $commandLog
        Assert-PureLiveCommandSucceeded 'Windows x64 build' -ExitCode $buildExitCode

        $windowsSource = Join-Path $repoRoot "build\windows\x64\runner\$configurationDirectory"
        $expectedPrefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
        $windowsSourceFull = [IO.Path]::GetFullPath($windowsSource)
        if (-not $windowsSourceFull.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows build output escaped the repository: $windowsSourceFull"
        }
        $runtimeState = @(
            Join-Path $windowsSource 'AppData'
            Join-Path $windowsSource 'IPTV_CACHE'
        ) | Where-Object { Test-Path -LiteralPath $_ }
        if ($runtimeState) {
            # A previously launched Debug/Release tree writes portable user
            # state beside its EXE. It is not a build input and must never be
            # copied into a distributable. Preserve it in an auditable local
            # quarantine instead of forcing a clean build or deleting data.
            $runtimeArchiveRoot = Join-Path $repoRoot (
                "local-artifacts\test-runtime\windows-$configurationLower-" +
                [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            )
            $runtimeArchiveRootFull = [IO.Path]::GetFullPath($runtimeArchiveRoot)
            $allowedArchivePrefix = [IO.Path]::GetFullPath((Join-Path $repoRoot 'local-artifacts\test-runtime')).TrimEnd('\') + '\'
            if (-not $runtimeArchiveRootFull.StartsWith($allowedArchivePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Windows runtime archive escaped the repository: $runtimeArchiveRootFull"
            }
            New-Item -ItemType Directory -Force -Path $runtimeArchiveRootFull | Out-Null
            foreach ($runtimePath in $runtimeState) {
                Move-Item -LiteralPath $runtimePath -Destination $runtimeArchiveRootFull
            }
            Write-Host "Archived Windows runtime state outside the package: $runtimeArchiveRootFull"
        }

        # Clean only the disposable packaging stage, never Flutter/CMake build state.
        $windowsPackage = Join-Path $repoRoot ".local-build\windows-package-$configurationLower"
        $windowsPackageFull = [IO.Path]::GetFullPath($windowsPackage)
        if (-not $windowsPackageFull.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows package staging escaped the repository: $windowsPackageFull"
        }
        if (Test-Path -LiteralPath $windowsPackageFull) {
            Remove-Item -LiteralPath $windowsPackageFull -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $windowsPackageFull | Out-Null
        $developmentExtensions = @('.exp', '.ilk', '.lib', '.pdb')
        $installManifest = Join-Path $repoRoot 'build\windows\x64\install_manifest.txt'
        if (-not (Test-Path -LiteralPath $installManifest -PathType Leaf)) {
            throw "Windows install manifest was not produced: $installManifest"
        }

        # Flutter/CMake incremental builds intentionally retain their output
        # directory. Plugins removed from pubspec can therefore leave obsolete
        # DLLs and asset folders behind. Package only the current CMake install
        # manifest instead of copying the whole Release directory.
        $manifestEntries = @(Get-Content -LiteralPath $installManifest | Where-Object { $_.Trim() })
        if ($manifestEntries.Count -eq 0) {
            throw 'Windows install manifest is empty.'
        }
        $windowsSourcePrefix = $windowsSourceFull.TrimEnd('\') + '\'
        $manifestSourceMarker = "\build\windows\x64\runner\$configurationDirectory\"
        foreach ($entry in $manifestEntries) {
            # Flutter may invoke CMake through its short/substituted P: path,
            # while this script runs from the long workspace path. Resolve the
            # manifest-relative suffix against our validated build directory.
            $normalizedEntry = $entry.Trim().Replace('/', '\')
            $markerIndex = $normalizedEntry.IndexOf($manifestSourceMarker, [StringComparison]::OrdinalIgnoreCase)
            if ($markerIndex -lt 0) {
                throw "Windows install manifest entry has an unexpected root: $normalizedEntry"
            }
            $relativePath = $normalizedEntry.Substring($markerIndex + $manifestSourceMarker.Length)
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                throw "Windows install manifest entry has no relative file: $normalizedEntry"
            }
            $sourceFile = [IO.Path]::GetFullPath((Join-Path $windowsSourceFull $relativePath))
            if (-not $sourceFile.StartsWith($windowsSourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Windows install manifest escaped the build output: $sourceFile"
            }
            if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                throw "Windows install manifest entry is missing: $sourceFile"
            }
            if ([IO.Path]::GetExtension($sourceFile).ToLowerInvariant() -in $developmentExtensions) {
                continue
            }

            $destination = Join-Path $windowsPackageFull $relativePath
            $destinationParent = Split-Path -Parent $destination
            if ($destinationParent) {
                New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
            }
            Copy-Item -LiteralPath $sourceFile -Destination $destination -Force
        }

        # Flutter's Windows runner executable is produced outside the CMake
        # install list. The in-app webview plugin also links the dynamic
        # WebView2 loader without adding it to that list. Keep this small,
        # reviewed runtime allowlist explicit rather than reopening the whole
        # incremental Release directory.
        $requiredRunnerFiles = @('pure_live.exe', 'WebView2Loader.dll')
        if ($Configuration -eq 'Release') {
            # These are app-local runtime files required by Flutter's Windows
            # deployment contract. CMake resolves the versions matching the
            # active MSVC toolset and adds them to the install manifest.
            $requiredRunnerFiles += @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
        }
        foreach ($requiredRunnerFile in $requiredRunnerFiles) {
            $sourceFile = Join-Path $windowsSourceFull $requiredRunnerFile
            if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                throw "Required Windows runner file is missing: $sourceFile"
            }
            Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $windowsPackageFull $requiredRunnerFile) -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $windowsPackageFull 'pure_live.exe') -PathType Leaf)) {
            throw 'The staged Windows package does not contain pure_live.exe.'
        }
        if ($Configuration -eq 'Release') {
            foreach ($runtimeFile in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
                if (-not (Test-Path -LiteralPath (Join-Path $windowsPackageFull $runtimeFile) -PathType Leaf)) {
                    throw "The staged Windows package is missing the app-local MSVC runtime: $runtimeFile"
                }
            }
        }
        $developmentFiles = Get-ChildItem -LiteralPath $windowsPackageFull -Recurse -File |
            Where-Object Extension -In $developmentExtensions
        if ($developmentFiles) {
            throw "Development-only files appeared in the Windows package: $($developmentFiles.FullName -join ', ')"
        }
        $obsoleteQuickJsFiles = Get-ChildItem -LiteralPath $windowsPackageFull -Recurse -File |
            Where-Object { $_.Name -in @('dart_quickjs.dll', 'flutter_js_plugin.dll', 'quickjs_c_bridge.dll') }
        if ($obsoleteQuickJsFiles) {
            throw "Retired QuickJS runtime files appeared in the Windows package: $($obsoleteQuickJsFiles.FullName -join ', ')"
        }

        $zipName = if ($Configuration -eq 'Release') {
            "PureLive-$artifactVersion-windows-x64-portable.zip"
        } else {
            "PureLive-$artifactVersion-windows-x64-debug.zip"
        }
        $zipPath = Join-Path $output $zipName
        Compress-Archive -Path (Join-Path $windowsPackageFull '*') -DestinationPath $zipPath -Force
        $artifactPaths += [IO.Path]::GetFullPath($zipPath)

        if ($Configuration -eq 'Release' -and -not $SkipInstaller) {
            $iscc = @(
                'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
                (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
            ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($iscc) {
                $iss = Join-Path $repoRoot 'windows\packaging\exe\local_release.iss'
                & $iscc "/DSourceDir=$windowsPackageFull" "/DAppVersion=$displayVersion" `
                    "/DArtifactVersion=$artifactVersion" "/DOutputDir=$output" $iss
                $installerExitCode = $LASTEXITCODE
                Assert-PureLiveCommandSucceeded 'Windows installer packaging' -ExitCode $installerExitCode
                $setup = Get-ChildItem $output -File -Filter '*windows-x64-setup.exe' | Select-Object -First 1
                if ($setup) { $artifactPaths += $setup.FullName }
            } else {
                Write-Warning 'Inno Setup 6 was not found; the portable ZIP was created.'
            }
        }
    $status = 'succeeded'
} catch {
    $failureMessage = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = ($_ | Out-String).Trim()
    }
    throw
} finally {
    $stopwatch.Stop()
    if ($monitor) { $resourceSummary = Stop-PureLiveResourceMonitor -Job $monitor }
    if ($lease) {
        $remainingHeavyProcesses = Wait-PureLiveBackgroundCpuSettle
        Exit-PureLiveHeavyTaskSlot -Lease $lease
    }

    $logText = if (Test-Path -LiteralPath $commandLog) { Get-Content -LiteralPath $commandLog -Raw } else { '' }
    $cacheSummary = [ordered]@{
        incremental_state_present_before = $incrementalStateBefore
        from_cache_observations = ([regex]::Matches($logText, '(?im)\bFROM-CACHE\b')).Count
        up_to_date_observations = ([regex]::Matches($logText, '(?im)\bUP-TO-DATE\b')).Count
        command_log = [IO.Path]::GetFullPath($commandLog)
    }
    $sourceCommit = (git rev-parse HEAD).Trim()
    $record = [ordered]@{
        schema_version = 1
        task = "build-$($Target.ToLowerInvariant())-$configurationLower"
        command = ".\tool\build_local_release.ps1 -Target $Target -Configuration $Configuration" +
            $(if ($DedicatedBuild) { ' -DedicatedBuild' } else { '' }) +
            $(if ($FullRegression) { ' -FullRegression' } else { ' -SkipQuality' })
        source_commit = $sourceCommit
        started_at_utc = $startedAt.ToString('o')
        duration_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        status = $status
        failure = $failureMessage
        target = $Target
        configuration = $Configuration
        quality = if ($FullRegression) { 'full-in-this-invocation' } else { 'external-focused-or-existing-evidence' }
        cache = $cacheSummary
        peak_resources = $resourceSummary
        active_heavy_processes_after = $remainingHeavyProcesses
        outputs = $artifactPaths
        package_metadata = $packageMetadata
        automatic_follow_up = $false
    }
    $recordPath = Write-PureLiveTaskRecord -RepoRoot $repoRoot -Record $record

    if ($status -eq 'succeeded') {
        $trackedDirty = [bool](git status --porcelain --untracked-files=no)
        $setupExecutable = Get-ChildItem $output -File -Filter '*windows-x64-setup.exe' | Select-Object -First 1
        $windowsPortable = Get-ChildItem $output -File -Filter '*windows-x64-*.zip' | Select-Object -First 1
        $windowsSigning = if ($setupExecutable -and (Get-AuthenticodeSignature -LiteralPath $setupExecutable.FullName).Status -eq 'Valid') {
            'authenticode'
        } elseif ($setupExecutable -or $windowsPortable) {
            'unsigned'
        } else {
            'not-built'
        }
        $metadataName = 'WINDOWS_BUILD_METADATA.json'
        $checksumName = 'WINDOWS_SHA256SUMS.txt'
        $metadataPath = Join-Path $output $metadataName
        [ordered]@{
            version = $fullVersion
            repository_version = $repositoryFullVersion
            built_at_utc = [DateTime]::UtcNow.ToString('o')
            source_commit = $sourceCommit
            tracked_files_dirty = $trackedDirty
            requested_target = $Target
            configuration = $Configuration
            windows_signing = $windowsSigning
            cache = $cacheSummary
            resource_record = [IO.Path]::GetFullPath($recordPath)
            build_source = 'local'
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding utf8

        # Hash only files produced by this target invocation. A platform may
        # intentionally share a version directory with an older platform
        # build, and its checksum manifest must never absorb unrelated assets.
        @($artifactPaths + $metadataPath) | Sort-Object -Unique | ForEach-Object {
            $file = Get-Item -LiteralPath $_
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            '{0} *{1}' -f $hash.Hash.ToLowerInvariant(), $file.Name
        } | Set-Content -Path (Join-Path $output $checksumName) -Encoding ascii
        Get-ChildItem $output -File | Select-Object Name, Length, LastWriteTime
    }
    Write-Host "Build record: $recordPath"

    Pop-Location
}
