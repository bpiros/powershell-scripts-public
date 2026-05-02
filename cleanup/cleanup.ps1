# cleanup.ps1 — System Cleanup Script
# Saves last run timestamp and a detailed log for each run.
# Run this script as Administrator.

param(
    [Alias("AcceptDefaults")]
    [switch]$NonInteractive,

    [Alias("WhatIf")]
    [switch]$DryRun
)

# --- Check for Administrator privileges ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$scriptDir = "$env:USERPROFILE\scripts\public"
$SystemDrive = $env:SystemDrive

if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }

$logDir = "$scriptDir\cleanup\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# --- Keep only the last 10 logs ---
Get-ChildItem "$logDir\cleanup-log-*.txt" -ErrorAction SilentlyContinue |
Sort-Object LastWriteTime -Descending |
Select-Object -Skip 10 |
Remove-Item -Force -ErrorAction SilentlyContinue

$timestampFile = "$logDir\cleanup-lastrun.txt"
$logFile = "$logDir\cleanup-log-$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$ageThreshold = (Get-Date).AddDays(-7)

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

    $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Promote non-terminating errors to terminating so the catch block fires.
    # Cmdlets that explicitly pass -ErrorAction SilentlyContinue are unaffected —
    # a per-call parameter always overrides the preference variable.
    $ErrorActionPreference = 'Stop'
    try {
        & $action
        $stepStopwatch.Stop()
        Log "       Done. [$($stepStopwatch.Elapsed.ToString('hh\:mm\:ss'))]" "Green"
    }
    catch {
        $stepStopwatch.Stop()
        Log "       ERROR: $_ (After $($stepStopwatch.Elapsed.ToString('hh\:mm\:ss')))" "Red"
    }
}

# --- Optional step prompt helper ---
function Ask-Optional {
    param([string]$question)
    if ($NonInteractive) {
        return $false
    }
    Write-Host ""
    Write-Host "  $question" -ForegroundColor Yellow
    Write-Host "  [Y] Yes   [N] No (default: N)" -ForegroundColor DarkGray
    $ans = Read-Host "  Your choice"
    return ($ans -match '^[Yy]')
}

# --- Measure $SystemDrive drive free space BEFORE ---
$diskBefore = (Get-PSDrive -Name ($SystemDrive -replace ':', '')).Free

# --- Show last run info ---
if (Test-Path $timestampFile) {
    $lastRun = Get-Content $timestampFile
    $lastRunDate = [datetime]::MinValue
    if ([datetime]::TryParse($lastRun, [ref]$lastRunDate)) {
        $daysSince = [math]::Floor((Get-Date - $lastRunDate).TotalDays)
        Log ""
        Log "============================================" "DarkCyan"
        Log "   SYSTEM CLEANUP SCRIPT" "Cyan"
        Log "============================================" "DarkCyan"
        Log ""
        Log "  Last run : $($lastRunDate.ToString('yyyy-MM-dd HH:mm'))" "Gray"
        if ($daysSince -gt 30) {
            Log "  Days ago : $daysSince day(s)  [Overdue!]" "Red"
        }
        elseif ($daysSince -gt 14) {
            Log "  Days ago : $daysSince day(s)" "Yellow"
        }
        else {
            Log "  Days ago : $daysSince day(s)" "Green"
        }
    }
    else {
        Log ""
        Log "============================================" "DarkCyan"
        Log "   SYSTEM CLEANUP SCRIPT" "Cyan"
        Log "============================================" "DarkCyan"
        Log ""
        Log "  Last run : Invalid or corrupted timestamp" "Yellow"
    }
}
else {
    Log ""
    Log "============================================" "DarkCyan"
    Log "   SYSTEM CLEANUP SCRIPT" "Cyan"
    Log "============================================" "DarkCyan"
    Log ""
    Log "  Last run : Never recorded" "Yellow"
}

Log ""
Log "  Starting cleanup at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "White"
if ($DryRun) { Log "  [DRY RUN MODE] No changes will be applied." "Yellow" }
Log "  Free space on $SystemDrive before: $([math]::Round($diskBefore / 1GB, 2)) GB" "Gray"
Log "  Log file: $logFile" "DarkGray"
Log "============================================" "DarkCyan"

# ─────────────────────────────────────────────
# Ask about optional steps upfront so the script can run unattended
# ─────────────────────────────────────────────
if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "   OPTIONAL STEPS — answer before we start" -ForegroundColor Cyan
    Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
}

$runSfc = Ask-Optional "[Optional A] Run System File Checker (sfc /scannow)?  [slow — ~10-30 min]"
$runDism = Ask-Optional "[Optional B] Run DISM RestoreHealth + ComponentCleanup?  [slow — ~20-60 min]"
$runChkdsk = Ask-Optional "[Optional C] Run CHKDSK read-only disk health scan?"
$removeWinOld = Ask-Optional "[Optional D] Show Windows.old removal guide? (Manual steps required for safe deletion)"
$runDocker = Ask-Optional "[Optional E] Prune unused Docker data? (Removes stopped containers and unused networks)"

Write-Host ""
Write-Host "  Choices recorded. Starting cleanup now..." -ForegroundColor Green
Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan

Log "  Optional choices: SFC=$runSfc, DISM=$runDism, CHKDSK=$runChkdsk, Windows.old=$removeWinOld, Docker=$runDocker" "DarkGray"

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ─────────────────────────────────────────────
# PRE-STEP: Create a System Restore Point
# Gives you a rollback safety net before anything is deleted.
# Protects against edge cases in steps that modify system files or services.
# ─────────────────────────────────────────────
Run-Step "[Pre] Creating System Restore Point..." {
    Log "       This may take a moment..." "DarkGray"

    # --- Check how recent the last restore point is ---
    $lastRP = Get-CimInstance -Namespace "root\default" -ClassName SystemRestore |
    Sort-Object CreationTime -Descending |
    Select-Object -First 1

    if ($lastRP) {
        $hoursSinceLast = [math]::Round(((Get-Date) - $lastRP.CreationTime).TotalHours, 1)
        Log "       Most recent restore point: '$($lastRP.Description)' ($hoursSinceLast h ago)" "DarkGray"
    }

    # --- Temporarily disable the 24-hour frequency throttle ---
    # Windows ignores Checkpoint-Computer if a restore point exists within the last 24 h.
    # Setting SystemRestorePointCreationFrequency=0 bypasses this limit for this call only.
    $rpFreqKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
    $rpFreqName = "SystemRestorePointCreationFrequency"
    $originalFreq = (Get-ItemProperty -Path $rpFreqKey -Name $rpFreqName -ErrorAction SilentlyContinue).$rpFreqName

    try {
        Set-ItemProperty -Path $rpFreqKey -Name $rpFreqName -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

        $restorePointDesc = "Pre-Cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        
        if (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue) {
            Checkpoint-Computer -Description $restorePointDesc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        }
        else {
            # PowerShell Core (pwsh) does not have Checkpoint-Computer. Fall back to Windows PowerShell 5.1.
            Log "       Delegating restore point to Windows PowerShell 5.1..." "DarkGray"
            $psArgs = "-NoProfile -Command `"Checkpoint-Computer -Description '$restorePointDesc' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop`""
            $proc = Start-Process powershell.exe -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden
            if ($proc.ExitCode -ne 0) {
                throw "powershell.exe exited with code $($proc.ExitCode)."
            }
        }

        # Verify the point was actually created
        $newRP = Get-CimInstance -Namespace "root\default" -ClassName SystemRestore |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1
        if ($newRP -and $newRP.Description -eq $restorePointDesc) {
            Log "       Restore point created: $restorePointDesc" "Green"
        }
        else {
            Log "       [WARN] Restore point may not have been created — verify in System Protection." "Yellow"
        }
    }
    catch {
        Log "       [WARN] Could not create restore point: $_" "Yellow"
        Log "       Continuing without a restore point — proceed with caution." "Yellow"
    }
    finally {
        # Restore the original frequency value (or remove the key if it didn't exist before)
        if ($null -ne $originalFreq) {
            Set-ItemProperty -Path $rpFreqKey -Name $rpFreqName -Value $originalFreq -Type DWord -Force -ErrorAction SilentlyContinue
        }
        else {
            Remove-ItemProperty -Path $rpFreqKey -Name $rpFreqName -ErrorAction SilentlyContinue
        }
    }
}

# ─────────────────────────────────────────────
# STEP 1: Clear Temp folders (files older than 7 days) + empty folders
# ─────────────────────────────────────────────
Run-Step "[1/12] Clearing Temp folders (files older than 7 days) and empty folders..." {

    $totalFiles = 0
    $totalFolders = 0
    $totalBytes = 0

    # --- Folders to scan recursively ---
    $tempFolders = @(
        "$env:TEMP",
        "$SystemDrive\Windows\Temp",
        "$SystemDrive\Windows\Logs\CBS",
        "$SystemDrive\Windows\Logs\DISM",
        "$SystemDrive\ProgramData\Microsoft\Windows\WER\ReportQueue"
    )

    # --- Wildcard user profile folders (resolved per user on the machine) ---
    $userFolders = @(
        "$SystemDrive\Users\*\AppData\Local\Temp",
        "$SystemDrive\Users\*\AppData\Local\Microsoft\Windows\INetCookies",
        "$SystemDrive\Users\*\AppData\Local\CrashDumps",
        "$SystemDrive\Users\*\AppData\Local\Microsoft\Windows\WER"
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
            $foundCount = ($files | Measure-Object).Count
            $foundBytes = ($files | Measure-Object -Property Length -Sum).Sum

            $sizeLabel = if ($foundBytes -ge 1GB) { "$([math]::Round($foundBytes / 1GB, 2)) GB" } else { "$([math]::Round($foundBytes / 1MB, 1)) MB" }

            Log "         Found $foundCount file(s) to delete ($sizeLabel)" "DarkGray"
            
            if (-not $DryRun) {
                $files | ForEach-Object {
                    $len = $_.Length
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $_.FullName)) {
                        $totalFiles++
                        $totalBytes += $len
                    }
                }
            }
            else {
                $totalFiles += $foundCount
                $totalBytes += $foundBytes
            }
        }
        else {
            Log "         No files older than 7 days found." "DarkGray"
        }

        # Remove leftover empty folders (bottom-up: deepest first so parents become empty in the same pass)
        $allDirs = Get-ChildItem -Path $folder -Directory -Recurse -Force -ErrorAction SilentlyContinue
        if ($allDirs) {
            $allDirs |
            Sort-Object { ($_.FullName -split '\\').Count } -Descending |
            ForEach-Object {
                $hasItems = Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $hasItems) {
                    if (-not $DryRun) { 
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue 
                        if (-not (Test-Path -LiteralPath $_.FullName)) { $totalFolders++ }
                    }
                    else { $totalFolders++ }
                }
            }
        }
    }

    # --- Handle .dmp crash dump files in $SystemDrive\Windows separately ---
    Log "       Scanning: $SystemDrive\Windows (*.dmp files only)" "DarkGray"
    $dmpFiles = Get-ChildItem -Path "$SystemDrive\Windows" -Filter "*.dmp" -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $ageThreshold }

    if ($dmpFiles) {
        $dmpCount = ($dmpFiles | Measure-Object).Count
        $dmpBytes = ($dmpFiles | Measure-Object -Property Length -Sum).Sum
        $dmpLabel = if ($dmpBytes -ge 1GB) { "$([math]::Round($dmpBytes/1GB,2)) GB" } else { "$([math]::Round($dmpBytes/1MB,1)) MB" }
        Log "         Found $dmpCount .dmp file(s) to delete ($dmpLabel)" "DarkGray"
        
        if (-not $DryRun) {
            $dmpFiles | ForEach-Object {
                $len = $_.Length
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $_.FullName)) {
                    $totalFiles++
                    $totalBytes += $len
                }
            }
        }
        else {
            $totalFiles += $dmpCount
            $totalBytes += $dmpBytes
        }
    }
    else {
        Log "         No .dmp files older than 7 days found." "DarkGray"
    }

    # --- Step summary ---
    $totalLabel = if ($totalBytes -ge 1GB) { "$([math]::Round($totalBytes/1GB,2)) GB" } else { "$([math]::Round($totalBytes/1MB,1)) MB" }
    if ($DryRun) {
        Log "       [DRY RUN] Total: $totalFiles file(s) would be deleted ($totalLabel), $totalFolders empty folder(s) would be removed." "Yellow"
    }
    else {
        Log "       Total: $totalFiles file(s) deleted ($totalLabel), $totalFolders empty folder(s) removed." "Green"
    }
}

# ─────────────────────────────────────────────
# STEP 2: Auto-configure and run Disk Cleanup (cleanmgr)
# A random profile number (8000-9999) is used to avoid collisions.
# cleanmgr is launched with PassThru so we can monitor execution —
# the /sagerun flag skips the drive-selection GUI.
# cleanmgr is not present on Windows Server; the step is skipped.
# ─────────────────────────────────────────────
Run-Step "[2/12] Configuring and running Disk Cleanup (cleanmgr)..." {
    $cleanmgrPath = "$env:SystemRoot\System32\cleanmgr.exe"
    if (-not (Test-Path $cleanmgrPath)) {
        Log "       [SKIP] cleanmgr.exe not found (not available on this edition)." "DarkGray"
        return
    }

    $sageProfile = Get-Random -Minimum 8000 -Maximum 10000
    $flagName = "StateFlags$sageProfile"
    $volCaches = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
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

    try {
        foreach ($cat in $categories) {
            $path = Join-Path $volCaches $cat
            if (Test-Path $path) {
                if (-not $DryRun) { Set-ItemProperty -Path $path -Name $flagName -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue }
            }
        }

        if ($DryRun) {
            Log "       [DRY RUN] Would launch cleanmgr /sagerun:$sageProfile." "Yellow"
            return
        }

        Log "       Launching cleanmgr /sagerun:$sageProfile (Synchronous)..." "DarkGray"
        $proc = Start-Process -FilePath $cleanmgrPath -ArgumentList "/sagerun:$sageProfile" -PassThru -ErrorAction Stop
        $startTime = Get-Date
        $spinner = @('|', '/', '-', '\')
        $counter = 0

        while (-not $proc.HasExited) {
            $elapsed = (Get-Date) - $startTime
            # Spinner only on console to avoid log bloat
            Write-Host -NoNewline "`r       Still working... $($spinner[$counter % 4]) [$($elapsed.ToString('mm\:ss'))]   " -ForegroundColor DarkGray
            $counter++
            Start-Sleep -Milliseconds 500
            
            # Log a heartbeat to the file every 2 minutes
            if ($counter % 240 -eq 0) { 
                Add-Content -Path $logFile -Value "[$(Get-Date -Format 'HH:mm:ss')] cleanmgr still active ($($elapsed.ToString('mm\:ss')) elapsed)..."
            }
        }
        Write-Host "" # Newline to clear the spinner line
        Log "       cleanmgr completed (exit code: $($proc.ExitCode))." "DarkGray"
    }
    finally {
        if (-not $DryRun) {
            # Clean up the registry flags
            foreach ($cat in $categories) {
                $path = Join-Path $volCaches $cat
                if (Test-Path $path) {
                    Remove-ItemProperty -Path $path -Name $flagName -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# ─────────────────────────────────────────────
# STEP 3: Clear Windows Update download cache
# Preserves the 'DataStore' folder to keep Windows Update history/metadata.
# BITS and DoSvc are also stopped to prevent file-locking conflicts.
# try/finally guarantees all three services restart even if deletion fails.
# ─────────────────────────────────────────────
Run-Step "[3/12] Clearing Windows Update download cache..." {
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $installer = $updateSession.CreateUpdateInstaller()
        if ($installer.IsBusy) {
            Log "       [SKIP] Windows Update is actively installing updates. Skipping cache clearance to avoid interrupting." "Yellow"
            return
        }
    }
    catch {
        Log "       [WARN] Could not query Windows Update Agent API. Proceeding with caution." "Yellow"
    }

    Log "       Stopping Windows Update, BITS, and Delivery Optimization services..." "DarkGray"
    if (-not $DryRun) { 
        Stop-Service -Name wuauserv, BITS, DoSvc -Force -ErrorAction SilentlyContinue 
        Start-Sleep -Seconds 2
    }
    try {
        if (-not $DryRun) { Remove-Item -Path "$SystemDrive\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue }
        else { Log "       [DRY RUN] Would clear SoftwareDistribution\Download cache." "Yellow" }
    }
    finally {
        Log "       Restarting Windows Update, BITS, and Delivery Optimization services..." "DarkGray"
        if (-not $DryRun) { Start-Service -Name wuauserv, BITS, DoSvc -ErrorAction SilentlyContinue }
    }
}

# ─────────────────────────────────────────────
# STEP 4: Clear winget download cache
# ─────────────────────────────────────────────
Run-Step "[4/12] Clearing winget download cache..." {
    if (-not $DryRun) {
        Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalCache\Roaming\Microsoft\WinGet\Packages\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Log "       [DRY RUN] Would clear winget download cache." "Yellow"
    }
}

# ─────────────────────────────────────────────
# STEP 5: Clear Scoop cache
# ─────────────────────────────────────────────
Run-Step "[5/12] Clearing Scoop cache..." {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        if (-not $DryRun) { scoop cache rm * }
        else { Log "       [DRY RUN] Would run: scoop cache rm *" "Yellow" }
        Log "       Scoop cache cleared." "DarkGray"
    }
    else {
        Log "       Scoop not found — skipping." "DarkGray"
    }
}

# ─────────────────────────────────────────────
# STEP 6: Clear developer tool caches (pip, npm, NuGet, Docker)
# ─────────────────────────────────────────────
Run-Step "[6/12] Clearing developer tool caches..." {
    if (Get-Command pip -ErrorAction SilentlyContinue) {
        Log "       [pip] found — clearing cache..." "DarkGray"
        if (-not $DryRun) { pip cache purge }
        else { Log "       [DRY RUN] Would run: pip cache purge" "Yellow" }
    }
    else {
        Log "       [pip] not found — skipping." "DarkGray"
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Log "       [npm] found — clearing cache..." "DarkGray"
        if (-not $DryRun) { npm cache clean --force }
        else { Log "       [DRY RUN] Would run: npm cache clean --force" "Yellow" }
    }
    else {
        Log "       [npm] not found — skipping." "DarkGray"
    }

    # --- NuGet / .NET caches ---
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        Log "       [dotnet] found — clearing NuGet locals..." "DarkGray"
        if (-not $DryRun) { dotnet nuget locals all --clear }
        else { Log "       [DRY RUN] Would run: dotnet nuget locals all --clear" "Yellow" }
    }
    else {
        Log "       [dotnet] not found — skipping NuGet cleanup." "DarkGray"
    }


}

# ─────────────────────────────────────────────
# STEP 7: Clear selected low-value Windows Event Logs
# Only a targeted list is cleared — full log history is preserved for
# troubleshooting crashes, security audits, and update failures.
# ─────────────────────────────────────────────
Run-Step "[7/12] Clearing selected low-value Windows Event Logs..." {
    $logsToClear = @(
        "Microsoft-Windows-Diagnostics-Performance/Operational",
        "Microsoft-Windows-ResourceExhaustion-Detector/Operational",
        "Microsoft-Windows-Diagnostics-Networking/Operational",
        "Microsoft-Windows-StorageSpaces-Driver/Operational",
        "Microsoft-Windows-DriverFrameworks-UserMode/Operational"
    )
    foreach ($log in $logsToClear) {
        if (-not $DryRun) {
            wevtutil cl "$log" 2>$null
            if ($LASTEXITCODE -ne 0) { Log "       [WARN] Could not clear: $log (exit code $LASTEXITCODE)" "Yellow" }
            else { Log "       Cleared: $log" "DarkGray" }
        }
        else {
            Log "       [DRY RUN] Would clear: $log" "Yellow"
        }
    }
}

# ─────────────────────────────────────────────
# STEP 8: Clear DNS Cache
# ─────────────────────────────────────────────
Run-Step "[8/12] Flushing DNS cache..." {
    if (-not $DryRun) { Clear-DnsClientCache }
    else { Log "       [DRY RUN] Would flush DNS cache." "Yellow" }
}

# ─────────────────────────────────────────────
# STEP 9: Clear Windows Store cache
# The -i flag runs wsreset silently (avoids the Store window popping up
# on newer Windows 10/11 builds).
# wsreset.exe spawns a child process and returns immediately, so -Wait
# only catches the launcher exit. A Sleep buffer is used instead.
# ─────────────────────────────────────────────
Run-Step "[9/12] Clearing Windows Store cache (wsreset)..." {
    if (-not $DryRun) {
        Start-Process wsreset.exe -ArgumentList "-i" -NoNewWindow
    }
    else {
        Log "       [DRY RUN] Would launch wsreset.exe -i." "Yellow"
    }
    Log "       Waiting 15 seconds for silent wsreset to complete..." "DarkGray"
    Start-Sleep -Seconds 15
}

# ─────────────────────────────────────────────
# STEP 10: Flush thumbnail and font caches
# Uses ie4uinit.exe to refresh icon/thumb caches without killing Explorer.
# ─────────────────────────────────────────────
Run-Step "[10/12] Flushing thumbnail and font caches..." {
    # Thumbnail/Icon cache (non-destructive refresh)
    Log "       Refreshing icon and thumbnail cache..." "DarkGray"
    if (Test-Path "$env:WinDir\System32\ie4uinit.exe") {
        if (-not $DryRun) { Start-Process "ie4uinit.exe" -ArgumentList "-show" -Wait }
        else { Log "       [DRY RUN] Would launch ie4uinit.exe -show." "Yellow" }
    }

    # Font cache (standard service-based flush)
    Log "       Flushing font cache..." "DarkGray"
    if (-not $DryRun) {
        Stop-Service -Name "FontCache" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WinDir\ServiceProfiles\LocalService\AppData\Local\FontCache\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
    }
    else {
        Log "       [DRY RUN] Would flush font cache." "Yellow"
    }
}

# ─────────────────────────────────────────────
# STEP 11: Clear browser caches
# Skips any browser that is currently running to avoid session corruption.
# ─────────────────────────────────────────────
Run-Step "[11/12] Clearing browser caches..." {
    $browsers = @{
        "Google Chrome"   = @(
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\DawnCache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache\*"
        )
        "Microsoft Edge"  = @(
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Code Cache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\DawnCache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\GPUCache\*"
        )
        "Brave"           = @(
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Cache\*",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Code Cache\*",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\DawnCache\*",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\GPUCache\*"
        )
        "Mozilla Firefox" = @(
            "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2\entries\*",
            "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2\doomed\*"
        )
    }
    $browserProcessNames = @{
        "Google Chrome"   = "chrome"
        "Microsoft Edge"  = "msedge"
        "Brave"           = "brave"
        "Mozilla Firefox" = "firefox"
    }
    foreach ($browser in $browsers.Keys) {
        $processName = $browserProcessNames[$browser]
        
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
            Log "       [$browser] is currently running — skipping to avoid session corruption." "Yellow"
            continue
        }

        # Check if any cache paths actually exist before logging "found"
        $cacheExists = $false
        foreach ($cachePath in $browsers[$browser]) {
            if (Test-Path $cachePath) {
                $cacheExists = $true
                break
            }
        }

        if ($cacheExists) {
            Log "       [$browser] found — clearing cache..." "DarkGray"
            foreach ($cachePath in $browsers[$browser]) {
                if (-not $DryRun) { Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue }
            }
            if ($DryRun) { Log "       [DRY RUN] Would clear [$browser] cache." "Yellow" }
            else { Log "       [$browser] cache cleared." "DarkGray" }
        }
        else {
            Log "       [$browser] not found — skipping." "DarkGray"
        }
    }
}

# ─────────────────────────────────────────────
# STEP 12: Surgical Android Studio and Gradle Cleanup
# Removes outdated logs and caches (older than 7-30 days)
# while keeping active dependencies and recent distributions.
# ─────────────────────────────────────────────
Run-Step "[12/12] Surgical Android Studio and Gradle Cleanup..." {
    # 1. Check if Android Studio is running
    if (Get-Process -Name "studio64", "studio" -ErrorAction SilentlyContinue) {
        Log "       [Android Studio] is currently running — skipping to avoid workspace corruption." "Yellow"
        return
    }
    
    if (Get-Command gradle -ErrorAction SilentlyContinue) {
        Log "       Shutting down Gradle daemons gracefully..." "DarkGray"
        if (-not $DryRun) { gradle --stop 2>&1 | Out-Null }
        else { Log "       [DRY RUN] Would run: gradle --stop" "Yellow" }
    }
    Start-Sleep -Seconds 3

    $now = Get-Date
    $old30 = $now.AddDays(-30)
    $old7 = $now.AddDays(-7)

    # 2. Targeted Gradle Cleanup
    $gradleBase = "$env:USERPROFILE\.gradle"
    if (Test-Path $gradleBase) {
        Log "       Cleaning outdated Gradle components (30+ days)..." "DarkGray"
        # Clean old Gradle distributions
        if (Test-Path "$gradleBase\wrapper\dists") {
            if (-not $DryRun) {
                Get-ChildItem -Path "$gradleBase\wrapper\dists" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $old30 } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            else { Log "       [DRY RUN] Would clean old Gradle distributions (30+ days)." "Yellow" }
        }

        # Clear daemon logs entirely (they are just text logs)
        if (Test-Path "$gradleBase\daemon") {
            if (-not $DryRun) {
                Get-ChildItem -Path "$gradleBase\daemon" -Filter "*.log" -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
            else { Log "       [DRY RUN] Would clear Gradle daemon logs." "Yellow" }
        }
    }

    # 3. Android Studio Logs and Tmp (7+ days)
    Get-ChildItem "$env:LOCALAPPDATA\Google" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "AndroidStudio*" } |
    ForEach-Object {
        $asFolder = $_.FullName
        Log "       Cleaning logs/tmp for $($_.Name)..." "DarkGray"
            
        # Logs
        if (Test-Path "$asFolder\log") {
            if (-not $DryRun) {
                Get-ChildItem -Path "$asFolder\log" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $old7 } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
            else { Log "       [DRY RUN] Would clean AS logs for $($_.Name) (7+ days)." "Yellow" }
        }
            
        # Tmp
        if (Test-Path "$asFolder\tmp") {
            if (-not $DryRun) {
                Get-ChildItem -Path "$asFolder\tmp" -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $old7 } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            else { Log "       [DRY RUN] Would clean AS tmp for $($_.Name) (7+ days)." "Yellow" }
        }
    }

    # 4. Kotlin Compiler Cache
    $kotlinCache = "$env:LOCALAPPDATA\Kotlin\cache"
    if (Test-Path $kotlinCache) {
        Log "       Cleaning Kotlin compiler cache (30+ days)..." "DarkGray"
        if (-not $DryRun) {
            Get-ChildItem -Path $kotlinCache -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $old30 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        else { Log "       [DRY RUN] Would clean Kotlin compiler cache (30+ days)." "Yellow" }
    }

}

# ─────────────────────────────────────────────
# Optional A: SFC - System File Checker
# ─────────────────────────────────────────────
if ($runSfc) {
    Run-Step "[Optional A] Running System File Checker (sfc /scannow)..." {
        Log "       This may take several minutes..." "DarkGray"
        if (-not $DryRun) {
            sfc /scannow
            if ($LASTEXITCODE -ne 0) { Log "       SFC exited with code $LASTEXITCODE — review the log." "Yellow" }
        }
        else { Log "       [DRY RUN] Would run: sfc /scannow" "Yellow" }
    }
}
else {
    Log ""
    Log "[Optional A] SFC — skipped by user." "DarkGray"
}

# ─────────────────────────────────────────────
# Optional B: DISM - Repair and Cleanup
# /ResetBase omitted — irreversible and too destructive for routine use.
# ─────────────────────────────────────────────
if ($runDism) {
    Run-Step "[Optional B] Running DISM RestoreHealth + ComponentCleanup..." {
        Log "       This may take several minutes..." "DarkGray"
        if (-not $DryRun) {
            dism /Online /Cleanup-Image /RestoreHealth
            if ($LASTEXITCODE -ne 0) { Log "       DISM RestoreHealth exited with code $LASTEXITCODE — review the log." "Yellow" }
            dism /Online /Cleanup-Image /StartComponentCleanup
            if ($LASTEXITCODE -ne 0) { Log "       DISM ComponentCleanup exited with code $LASTEXITCODE — review the log." "Yellow" }
        }
        else { Log "       [DRY RUN] Would run DISM RestoreHealth + ComponentCleanup." "Yellow" }
    }
}
else {
    Log ""
    Log "[Optional B] DISM — skipped by user." "DarkGray"
}

# ─────────────────────────────────────────────
# Optional C: CHKDSK scan (read-only, no changes)
# ─────────────────────────────────────────────
if ($runChkdsk) {
    Run-Step "[Optional C] Running CHKDSK disk health scan (read-only)..." {
        Log "       This is a read-only scan — no changes will be made." "DarkGray"
        chkdsk $SystemDrive /scan
        if ($LASTEXITCODE -ne 0) { Log "       CHKDSK exited with code $LASTEXITCODE — review the log." "Yellow" }
    }
}
else {
    Log ""
    Log "[Optional C] CHKDSK — skipped by user." "DarkGray"
}

# ─────────────────────────────────────────────
# Optional D: Remove Windows.old folder
# WARNING: IRREVERSIBLE — cannot roll back Windows version after this.
# ─────────────────────────────────────────────
if ($removeWinOld) {
    Run-Step "[Optional D] Windows.old Removal Instructions" {
        Log "       Windows.old requires elevated system permissions to remove safely." "Yellow"
        Log "       Manual steps are recommended to avoid leaving corrupted fragments:" "Gray"
        Log ""
        Log "       Option 1 (Easiest):" "Cyan"
        Log "         1. Open Start, type 'Disk Cleanup', and Run as Administrator." "Gray"
        Log "         2. Select ($SystemDrive) and click 'OK'." "Gray"
        Log "         3. Check 'Previous Windows installation(s)' and click 'OK'." "Gray"
        Log ""
        Log "       Option 2 (Command Line):" "Cyan"
        Log "         Run the following in an Administrator PowerShell window:" "Gray"
        Log "         RD /S /Q $SystemDrive\Windows.old" "White"
        Log "         (Note: This may require taking ownership of the folder first)" "DarkGray"
    }
}
else {
    Log ""
    Log "[Optional D] Windows.old guide — skipped by user." "DarkGray"
}

# ─────────────────────────────────────────────
# Optional E: Docker System Prune
# ─────────────────────────────────────────────
if ($runDocker) {
    Run-Step "[Optional E] Pruning unused Docker data..." {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            Log "       Pruning unused Docker system data (containers, networks, dangling images)..." "DarkGray"
            if (-not $DryRun) {
                docker system prune -f
            }
            else {
                Log "       [DRY RUN] Would run: docker system prune -f" "Yellow"
            }
        }
        else {
            Log "       [Docker] not found — skipping." "DarkGray"
        }
    }
}
else {
    Log ""
    Log "[Optional E] Docker cleanup — skipped by user." "DarkGray"
}

# ─────────────────────────────────────────────
# Final: Measure disk space, save timestamp, show summary
# ─────────────────────────────────────────────
$diskAfter = (Get-PSDrive -Name ($SystemDrive -replace ':', '')).Free
$freedBytes = $diskAfter - $diskBefore

if (-not $DryRun) {
    (Get-Date).ToString('o') | Set-Content $timestampFile
}
else {
    Log "       [DRY RUN] Skipping last-run timestamp update." "DarkGray"
}

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
}
elseif ($freedBytes -gt 0) {
    $freedMB = [math]::Round($freedBytes / 1MB, 1)
    Log "  Space freed : $freedMB MB" "Yellow"
}
elseif ($freedBytes -lt 0) {
    $usedMB = [math]::Round([math]::Abs($freedBytes) / 1MB, 1)
    Log "  Space freed : -$usedMB MB (disk usage increased — other processes may have written data during cleanup)" "Yellow"
}
else {
    Log "  Space freed : 0 (no measurable change)" "DarkGray"
}

Log ""
Log "  Full log saved to: $logFile" "DarkGray"
Log ""

$stopwatch.Stop()
Log "  Total time  : $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))" "Gray"

Write-Warning "A RESTART IS RECOMMENDED to apply all changes fully."
Write-Host ""