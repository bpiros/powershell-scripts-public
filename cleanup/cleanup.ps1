# cleanup.ps1 — System Cleanup Script
# Saves last run timestamp and a detailed log for each run.
# Run this script as Administrator.

$scriptDir     = "$env:USERPROFILE\scripts\public"
if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }

# --- Keep only the last 10 logs ---
Get-ChildItem "$scriptDir\cleanup-log-*.txt" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 10 |
    Remove-Item -Force -ErrorAction SilentlyContinue

$timestampFile = "$scriptDir\cleanup-lastrun.txt"
$logFile       = "$scriptDir\cleanup-log-$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$ageThreshold  = (Get-Date).AddDays(-7)

# --- Logging function ---
function Log {
    param([string]$msg, [string]$color = "White")
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'HH:mm:ss')] $msg"
}

# --- Step runner with error handling ---
function Run-Step {
    param([string]$label, [scriptblock]$action)
    Log ""
    Log $label "Cyan"
    try {
        & $action
        Log "       Done." "Green"
    } catch {
        Log "       ERROR: $_" "Red"
    }
}

# --- Measure C: drive free space BEFORE ---
$diskBefore = (Get-PSDrive -Name C).Free

# --- Show last run info ---
if (Test-Path $timestampFile) {
    $lastRun     = Get-Content $timestampFile
    $lastRunDate = [datetime]$lastRun
    $daysSince   = [math]::Floor((Get-Date - $lastRunDate).TotalDays)
    Log ""
    Log "============================================" "DarkCyan"
    Log "   SYSTEM CLEANUP SCRIPT" "Cyan"
    Log "============================================" "DarkCyan"
    Log ""
    Log "  Last run : $($lastRunDate.ToString('yyyy-MM-dd HH:mm'))" "Gray"
    if ($daysSince -gt 30) {
        Log "  Days ago : $daysSince day(s)  [Overdue!]" "Red"
    } elseif ($daysSince -gt 14) {
        Log "  Days ago : $daysSince day(s)" "Yellow"
    } else {
        Log "  Days ago : $daysSince day(s)" "Green"
    }
} else {
    Log ""
    Log "============================================" "DarkCyan"
    Log "   SYSTEM CLEANUP SCRIPT" "Cyan"
    Log "============================================" "DarkCyan"
    Log ""
    Log "  Last run : Never recorded" "Yellow"
}

Log ""
Log "  Starting cleanup at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "White"
Log "  Free space on C: before: $([math]::Round($diskBefore / 1GB, 2)) GB" "Gray"
Log "  Log file: $logFile" "DarkGray"
Log "============================================" "DarkCyan"

# ─────────────────────────────────────────────
# PRE-STEP: Create a System Restore Point
# Gives you a rollback safety net before anything is deleted.
# Protects against edge cases in steps that modify system files or services.
# ─────────────────────────────────────────────
Run-Step "[Pre] Creating System Restore Point..." {
    Log "       This may take a moment..." "DarkGray"
    $restorePointDesc = "Pre-Cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Checkpoint-Computer -Description $restorePointDesc -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
    Log "       Restore point created: $restorePointDesc" "DarkGray"
}

# ─────────────────────────────────────────────
# STEP 1: Empty Recycle Bin
# ─────────────────────────────────────────────
Run-Step "[1/15] Emptying Recycle Bin..." {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────
# STEP 2: Clear Temp folders (files older than 7 days) + empty folders
#         Prefetch: only .pf files not accessed in the last 14 days
# ─────────────────────────────────────────────
Run-Step "[2/15] Clearing Temp folders (files older than 7 days) and empty folders..." {

    $totalFiles   = 0
    $totalFolders = 0
    $totalBytes   = 0

    # --- Folders to scan recursively (Prefetch handled separately below) ---
    $tempFolders = @(
        "$env:TEMP",
        "C:\Windows\Temp",
        "C:\Windows\Logs\CBS",
        "C:\Windows\Logs\DISM",
        "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
    )

    # --- Wildcard user profile folders (resolved per user on the machine) ---
    $userFolders = @(
        "C:\Users\*\AppData\Local\Temp",
        "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies",
        "C:\Users\*\AppData\Local\CrashDumps",
        "C:\Users\*\AppData\Local\Microsoft\Windows\WER"
    )

    # Resolve wildcard user paths into real paths
    foreach ($pattern in $userFolders) {
        $resolved = Resolve-Path $pattern -ErrorAction SilentlyContinue
        if ($resolved) {
            $tempFolders += $resolved.Path
        }
    }

    # --- Scan and clean each folder ---
    foreach ($folder in $tempFolders) {
        if (-not (Test-Path $folder)) {
            Log "       [SKIP] Not found: $folder" "DarkGray"
            continue
        }

        Log "       Scanning: $folder" "DarkGray"

        $files = Get-ChildItem -Path $folder -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $ageThreshold }

        if ($files) {
            $count     = ($files | Measure-Object).Count
            $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum

            if ($sizeBytes -ge 1GB) {
                $sizeLabel = "$([math]::Round($sizeBytes / 1GB, 2)) GB"
            } else {
                $sizeLabel = "$([math]::Round($sizeBytes / 1MB, 1)) MB"
            }

            Log "         Found $count file(s) to delete ($sizeLabel)" "DarkGray"
            $files | Remove-Item -Force -ErrorAction SilentlyContinue
            $totalFiles  += $count
            $totalBytes  += $sizeBytes
        } else {
            Log "         No files older than 7 days found." "DarkGray"
        }

        # Remove leftover empty folders
        $emptyFolders = Get-ChildItem -Path $folder -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { (Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0 }

        if ($emptyFolders) {
            $emptyCount    = ($emptyFolders | Measure-Object).Count
            $totalFolders += $emptyCount
            Log "         Removing $emptyCount empty folder(s)..." "DarkGray"
            $emptyFolders | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    # --- Prefetch: only delete .pf files not accessed in the last 14 days ---
    $prefetchPath      = "C:\Windows\Prefetch"
    $prefetchThreshold = (Get-Date).AddDays(-14)

    if (Test-Path $prefetchPath) {
        Log "       Scanning: $prefetchPath (unused in last 14 days)" "DarkGray"

        # Check if NTFS LastAccessTime updates are enabled on this system
        $ntfsKey = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -ErrorAction SilentlyContinue).NtfsDisableLastAccessUpdate
        if ($ntfsKey -ne 0) {
            Log "       [WARN] LastAccessTime is disabled on this system — falling back to LastWriteTime for prefetch." "Yellow"
            $pfFiles = Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $prefetchThreshold }
        } else {
            $pfFiles = Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastAccessTime -lt $prefetchThreshold }
        }

        if ($pfFiles) {
            $pfCount = ($pfFiles | Measure-Object).Count
            $pfBytes = ($pfFiles | Measure-Object -Property Length -Sum).Sum
            $pfLabel = if ($pfBytes -ge 1GB) { "$([math]::Round($pfBytes/1GB,2)) GB" } else { "$([math]::Round($pfBytes/1MB,1)) MB" }
            Log "         Found $pfCount unused prefetch file(s) ($pfLabel)" "DarkGray"
            $pfFiles | Remove-Item -Force -ErrorAction SilentlyContinue
            $totalFiles += $pfCount
            $totalBytes += $pfBytes
        } else {
            Log "         No prefetch files unused for 14+ days found." "DarkGray"
        }
    } else {
        Log "       [SKIP] Prefetch folder not found." "DarkGray"
    }

    # --- Handle .dmp crash dump files in C:\Windows separately ---
    Log "       Scanning: C:\Windows (*.dmp files only)" "DarkGray"
    $dmpFiles = Get-ChildItem -Path "C:\Windows" -Filter "*.dmp" -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $ageThreshold }

    if ($dmpFiles) {
        $dmpCount = ($dmpFiles | Measure-Object).Count
        $dmpBytes = ($dmpFiles | Measure-Object -Property Length -Sum).Sum
        $dmpLabel = if ($dmpBytes -ge 1GB) { "$([math]::Round($dmpBytes/1GB,2)) GB" } else { "$([math]::Round($dmpBytes/1MB,1)) MB" }
        Log "         Found $dmpCount .dmp file(s) to delete ($dmpLabel)" "DarkGray"
        $dmpFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        $totalFiles += $dmpCount
        $totalBytes += $dmpBytes
    } else {
        Log "         No .dmp files older than 7 days found." "DarkGray"
    }

    # --- Step 2 summary ---
    $totalLabel = if ($totalBytes -ge 1GB) { "$([math]::Round($totalBytes/1GB,2)) GB" } else { "$([math]::Round($totalBytes/1MB,1)) MB" }
    Log "       Total: $totalFiles file(s) deleted ($totalLabel), $totalFolders empty folder(s) removed." "Green"
}

# ─────────────────────────────────────────────
# STEP 3: Auto-configure and run Disk Cleanup (cleanmgr)
# -Wait ensures cleanmgr finishes before Step 4 begins.
# StateFlags9901 is used to avoid collisions with other tools using profile 1.
# ─────────────────────────────────────────────
Run-Step "[3/15] Configuring and running Disk Cleanup (cleanmgr)..." {
    $volCaches  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $categories = @(
        'Temporary Files',
        'Recycle Bin',
        'Thumbnail Cache',
        'Windows Update Cleanup',
        'Delivery Optimization Files',
        'Windows Error Reporting Queue Files',
        'System error memory dump files',
        'Downloaded Program Files'
    )
    foreach ($cat in $categories) {
        $path = Join-Path $volCaches $cat
        if (Test-Path $path) {
            Set-ItemProperty -Path $path -Name 'StateFlags9901' -Value 2 -Type DWord -Force
        }
    }
    Start-Process cleanmgr -ArgumentList "/sagerun:9901" -Wait -NoNewWindow
}

# ─────────────────────────────────────────────
# STEP 4: Clear Windows Update cache
# BITS and DoSvc are also stopped to prevent file-locking conflicts.
# try/finally guarantees all three services restart even if deletion fails.
# ─────────────────────────────────────────────
Run-Step "[4/15] Clearing Windows Update cache..." {
    Log "       Stopping Windows Update, BITS, and Delivery Optimization services..." "DarkGray"
    Stop-Service -Name wuauserv, BITS, DoSvc -Force -ErrorAction SilentlyContinue
    try {
        Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        Log "       Restarting Windows Update, BITS, and Delivery Optimization services..." "DarkGray"
        Start-Service -Name wuauserv, BITS, DoSvc -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────
# STEP 5: Clear winget download cache
# ─────────────────────────────────────────────
Run-Step "[5/15] Clearing winget download cache..." {
    Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalCache\Roaming\Microsoft\WinGet\Packages\*" -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────
# STEP 6: Clear Scoop cache
# ─────────────────────────────────────────────
Run-Step "[6/15] Clearing Scoop cache..." {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        scoop cache rm *
        Log "       Scoop cache cleared." "DarkGray"
    } else {
        Log "       Scoop not found — skipping." "DarkGray"
    }
}

# ─────────────────────────────────────────────
# STEP 7: Clear developer tool caches (pip, npm)
# ─────────────────────────────────────────────
Run-Step "[7/15] Clearing developer tool caches..." {
    if (Get-Command pip -ErrorAction SilentlyContinue) {
        Log "       [pip] found — clearing cache..." "DarkGray"
        pip cache purge
    } else {
        Log "       [pip] not found — skipping." "DarkGray"
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Log "       [npm] found — clearing cache..." "DarkGray"
        npm cache clean --force
    } else {
        Log "       [npm] not found — skipping." "DarkGray"
    }
}

# ─────────────────────────────────────────────
# STEP 8: SFC - System File Checker
# ─────────────────────────────────────────────
Run-Step "[8/15] Running System File Checker (sfc /scannow)..." {
    Log "       This may take several minutes..." "DarkGray"
    sfc /scannow
    if ($LASTEXITCODE -ne 0) { Log "       SFC exited with code $LASTEXITCODE — review the log." "Yellow" }
}

# ─────────────────────────────────────────────
# STEP 9: DISM - Repair and Cleanup
# /ResetBase removed — it is irreversible and too destructive for routine use.
# Run it manually only if you need maximum space and your system is stable.
# ─────────────────────────────────────────────
Run-Step "[9/15] Running DISM RestoreHealth + ComponentCleanup..." {
    Log "       This may take several minutes..." "DarkGray"
    dism /Online /Cleanup-Image /RestoreHealth
    if ($LASTEXITCODE -ne 0) { Log "       DISM RestoreHealth exited with code $LASTEXITCODE — review the log." "Yellow" }
    dism /Online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -ne 0) { Log "       DISM ComponentCleanup exited with code $LASTEXITCODE — review the log." "Yellow" }
}

# ─────────────────────────────────────────────
# STEP 10: Clear selected low-value Windows Event Logs
# Only a targeted list is cleared — full log history is preserved for
# troubleshooting crashes, security audits, and update failures.
# ─────────────────────────────────────────────
Run-Step "[10/15] Clearing selected low-value Windows Event Logs..." {
    $logsToClear = @(
        "Microsoft-Windows-Diagnostics-Performance/Operational",
        "Microsoft-Windows-ResourceExhaustion-Detector/Operational",
        "Microsoft-Windows-Diagnostics-Networking/Operational",
        "Microsoft-Windows-StorageSpaces-Driver/Operational",
        "Microsoft-Windows-DriverFrameworks-UserMode/Operational"
    )
    foreach ($log in $logsToClear) {
        wevtutil cl "$log" 2>$null
        if ($LASTEXITCODE -ne 0) { Log "       [WARN] Could not clear: $log (exit code $LASTEXITCODE)" "Yellow" }
        else { Log "       Cleared: $log" "DarkGray" }
    }
}

# ─────────────────────────────────────────────
# STEP 11: Clear DNS Cache
# ─────────────────────────────────────────────
Run-Step "[11/15] Flushing DNS cache..." {
    Clear-DnsClientCache
}

# ─────────────────────────────────────────────
# STEP 12: Clear Windows Store cache
# wsreset.exe spawns a child process and returns immediately, so -Wait
# only catches the launcher exit. A Sleep buffer is used instead.
# ─────────────────────────────────────────────
Run-Step "[12/15] Clearing Windows Store cache (wsreset)..." {
    Start-Process wsreset.exe
    Log "       Waiting 15 seconds for wsreset to complete..." "DarkGray"
    Start-Sleep -Seconds 15
}

# ─────────────────────────────────────────────
# STEP 13: Flush thumbnail and font caches
# Explorer is verified to have restarted after being killed.
# ─────────────────────────────────────────────
Run-Step "[13/15] Flushing thumbnail and font caches..." {
    # Thumbnail cache
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
    # Verify Explorer restarted; force-launch if it didn't
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer
        Start-Sleep -Seconds 2
        Log "       Explorer restarted manually." "DarkGray"
    } else {
        Log "       Explorer is running." "DarkGray"
    }
    # Font cache
    Stop-Service -Name "FontCache" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:WinDir\ServiceProfiles\LocalService\AppData\Local\FontCache\*" -Force -ErrorAction SilentlyContinue
    Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────
# STEP 14: Clear browser caches
# Skips any browser that is currently running to avoid session corruption.
# ─────────────────────────────────────────────
Run-Step "[14/15] Clearing browser caches..." {
    $browsers = @{
        "Google Chrome"   = @(
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache\*"
        )
        "Microsoft Edge"  = @(
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache\*"
        )
        "Brave"           = @(
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache\*",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache\*"
        )
        "Mozilla Firefox" = @(
            "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2\entries\*",
            "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2\doomed\*"
        )
    }
    $browserExePaths = @{
        "Google Chrome"   = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        "Microsoft Edge"  = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
        "Brave"           = "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
        "Mozilla Firefox" = "C:\Program Files\Mozilla Firefox\firefox.exe"
    }
    $browserProcessNames = @{
        "Google Chrome"   = "chrome"
        "Microsoft Edge"  = "msedge"
        "Brave"           = "brave"
        "Mozilla Firefox" = "firefox"
    }
    foreach ($browser in $browsers.Keys) {
        $exePath     = $browserExePaths[$browser]
        $processName = $browserProcessNames[$browser]
        if (Test-Path $exePath) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                Log "       [$browser] is currently running — skipping to avoid session corruption." "Yellow"
                continue
            }
            Log "       [$browser] found — clearing cache..." "DarkGray"
            foreach ($cachePath in $browsers[$browser]) {
                Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Log "       [$browser] cache cleared." "DarkGray"
        } else {
            Log "       [$browser] not found — skipping." "DarkGray"
        }
    }
}

# ─────────────────────────────────────────────
# STEP 15: Clear Android Studio and Gradle caches
# Only studio64/studio processes are killed — NOT generic java.exe,
# which would terminate unrelated servers, games, or tools.
# ─────────────────────────────────────────────
Run-Step "[15/15] Clearing Android Studio caches..." {
    Get-Process -Name "studio64", "studio" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    $gradlePaths = @(
        "$env:USERPROFILE\.gradle\caches\*",
        "$env:USERPROFILE\.gradle\wrapper\dists\*"
    )
    foreach ($path in $gradlePaths) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem "$env:LOCALAPPDATA\Google" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "AndroidStudio*" } |
        ForEach-Object {
            Remove-Item "$($_.FullName)\caches\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$($_.FullName)\tmp\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

    $projectRoots = @(
        "$env:USERPROFILE\AndroidStudioProjects",
        "$env:USERPROFILE\Projects",
        "$env:USERPROFILE\source"
    )
    foreach ($root in $projectRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Recurse -Directory -Filter "build" -ErrorAction SilentlyContinue |
                Where-Object { Test-Path "$($_.FullName)\intermediates" } |
                ForEach-Object {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    Log "       Cleaned build folder: $($_.FullName)" "DarkGray"
                }
        }
    }
}

# ─────────────────────────────────────────────
# Optional: CHKDSK scan (read-only, no changes)
# ─────────────────────────────────────────────
Run-Step "[Optional] Running CHKDSK disk health scan (read-only)..." {
    Log "       This is a read-only scan — no changes will be made." "DarkGray"
    chkdsk C: /scan
    if ($LASTEXITCODE -ne 0) { Log "       CHKDSK exited with code $LASTEXITCODE — review the log." "Yellow" }
}

# ─────────────────────────────────────────────
# Optional: Remove Windows.old folder
# Set $removeWindowsOld = $true to enable.
# WARNING: This is IRREVERSIBLE — you will no longer be able to roll back
# your Windows version after enabling this.
# ─────────────────────────────────────────────
# $removeWindowsOld = $false
# if ($removeWindowsOld) {
#    Run-Step "[Optional] Removing Windows.old folder..." {
#         Remove-Item "C:\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue
#     }
# } else {
#     Log ""
#     Log "[Optional] Removing Windows.old — SKIPPED (set `$removeWindowsOld = `$true to enable)" "DarkGray"
# }

# ─────────────────────────────────────────────
# Final: Measure disk space, save timestamp, show summary
# ─────────────────────────────────────────────
$diskAfter  = (Get-PSDrive -Name C).Free
$freedBytes = $diskAfter - $diskBefore

(Get-Date).ToString('o') | Set-Content $timestampFile

Log ""
Log "============================================" "DarkCyan"
Log "   ALL STEPS COMPLETED" "Green"
Log "============================================" "DarkCyan"
Log ""
Log "  Disk space summary:" "White"
Log "  Free before : $([math]::Round($diskBefore / 1GB, 2)) GB" "Gray"
Log "  Free after  : $([math]::Round($diskAfter / 1GB, 2)) GB" "Gray"

if ($freedBytes -ge 1GB) {
    $freedGB = [math]::Round($freedBytes / 1GB, 2)
    Log "  Space freed : $freedGB GB" "Green"
} elseif ($freedBytes -gt 0) {
    $freedMB = [math]::Round($freedBytes / 1MB, 1)
    Log "  Space freed : $freedMB MB" "Yellow"
} else {
    Log "  Space freed : 0 (no measurable change)" "DarkGray"
}

# ─────────────────────────────────────────────
# Top 10 largest folders on C:
# ─────────────────────────────────────────────
Log ""
Log "============================================" "DarkCyan"
Log "   TOP 10 LARGEST FOLDERS ON C:" "Cyan"
Log "============================================" "DarkCyan"
Log "  (Calculating — this may take a moment...)" "DarkGray"

$topFolders = Get-ChildItem C:\ -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $size = (Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{ Folder = $_.FullName; SizeGB = [math]::Round($size / 1GB, 2) }
    } |
    Sort-Object SizeGB -Descending |
    Select-Object -First 10

foreach ($entry in $topFolders) {
    Log ("  {0,-45} {1,8} GB" -f $entry.Folder, $entry.SizeGB) "Gray"
}

Log ""
Log "  Full log saved to: $logFile" "DarkGray"
Log ""
Write-Warning "A RESTART IS RECOMMENDED to apply all changes fully."
Write-Host ""