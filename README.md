# Cleanup script

# System Cleanup Script (`cleanup.ps1`)

A robust, comprehensive PowerShell script designed to clean temp files, package manager caches, developer tool leftovers, and optimize disk space on Windows systems.

> [!IMPORTANT]
> **Administrator Privileges Required:** The script modifies system files, handles Windows services, clears event logs, and configures Registry keys. It must be run in an elevated PowerShell terminal (Run as Administrator).

---

## Features & Capabilities

### Core Features
- **Restore Point Protection:** Automatically creates a System Restore Point before executing any cleanup steps to ensure rollback capabilities in case of issues.
- **Log Management:** Saves execution logs under `$USERPROFILE\scripts\public\cleanup\logs` (retains only the last 10 logs to avoid clutter).
- **Safety Checks:** Automatically detects running applications (e.g., browsers, Android Studio) and skips their respective cache cleanups to prevent session or workspace corruption.
- **Dry Run Mode:** Supports previewing actions without deleting files.
- **Non-Interactive Mode:** Can run unattended (skips all optional tasks and uses defaults).
- **Disk Usage Stats:** Displays disk space usage stats (before vs. after) and highlights space saved.

---

## Detailed Step Breakdown

The script splits cleanup tasks into **Core Steps** (executed automatically) and **Optional Steps** (prompted interactively).

### 1. Core Cleanup Steps (Mandatory)
The following steps run sequentially:

| Step | Component | Description |
|---|---|---|
| **1/11** | Temp Folders | Recursively deletes files older than 7 days from User & System Temp, CBS logs, DISM logs, WER (Windows Error Reporting), and Crash Dumps (`*.dmp`). |
| **2/11** | Disk Cleanup (`cleanmgr`) | Pre-configures and runs the native Windows Disk Cleanup utility silently utilizing a random registry configuration (cleans Recycle Bin, Thumbnails, temporary files, etc.). |
| **3/11** | Windows Update Cache | Stops `wuauserv`, `BITS`, and `DoSvc` services and safely purges the Windows Update download cache (`SoftwareDistribution\Download`). |
| **4/11** | Winget Cache | Clears stored installer caches for the Windows Package Manager (Winget). |
| **5/11** | Scoop Cache | Purges installation cache files managed by Scoop. |
| **6/11** | Developer Tool Caches | Purges Python `pip` cache, Node.js `npm` cache, and `.NET` NuGet packages cache. |
| **7/11** | Low-Value Event Logs | Clears bulky, diagnostic-specific Windows Event Logs (Diagnostics-Performance, Network Diagnostics, StorageSpaces, etc.) while keeping critical safety logs. |
| **8/11** | DNS Cache | Flushes the local DNS client cache (`Clear-DnsClientCache`). |
| **9/11** | Windows Store Cache | Triggers a silent reset of the Windows Store cache (`wsreset.exe`). |
| **10/11** | Cache Reconstruction | Rebuilds and flushes system thumbnails, icon caches, and clears the Windows Font Cache. |
| **11/11** | IDE & Compiler Cache | Safely stops running Gradle daemons and cleans up old Android Studio logs/temp files (older than 7 days) and Kotlin compiler caches (older than 30 days). |

### 2. Optional Steps
During interactive runs, the script prompts the user upfront for these optional, slow, or potentially destructive actions:

- **[Optional A] System File Checker (`sfc /scannow`):** Scans and repairs corrupted Windows system files. *[Takes ~10-30 min]*
- **[Optional B] DISM RestoreHealth & ComponentCleanup:** Repairs the Windows image component store and cleans up superseded update components. *[Takes ~20-60 min]*
- **[Optional C] CHKDSK Health Scan:** Runs a read-only health scan on the system drive.
- **[Optional D] Windows.old Guide:** Prints manual instructions on how to safely delete `Windows.old` folders from past upgrades.
- **[Optional E] Docker System Prune:** Runs `docker system prune -f` to clean up stopped containers, unused networks, and dangling images.
- **[Optional F] Clear Browser Caches:** Deletes local cache, GPU cache, and shader caches for **Google Chrome**, **Microsoft Edge**, **Brave**, and **Mozilla Firefox**. *(Always skips running browsers to avoid corrupted sessions)*.

---

## Examples & Usage

### 1. Interactive Mode (Standard Run)
Prompts you for optional steps before launching the script.
```powershell
# Run the script (forces Bypass execution policy for the current run)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1
```

### 2. Dry Run / Preview Mode
Runs all checks and logic, but does **not** delete any files or apply changes. Useful for seeing how much disk space could potentially be reclaimed.
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1 -DryRun
```

### 3. Non-Interactive / Unattended Mode
Runs only the core mandatory steps (1 to 11) using defaults without prompting for any user input. Optional steps are skipped.
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1 -NonInteractive
```

---

## Logs & History

Logs are written to:
`$env:USERPROFILE\scripts\public\cleanup\logs\`

- **`cleanup-lastrun.txt`**: Contains the ISO timestamp of the last successful script run.
- **`cleanup-log-YYYYMMDD_HHMMSS.txt`**: Detailed logs generated per run containing exactly which folders were scanned, errors encountered, and details of space freed.
