#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Safe Windows Maintenance & Disk Cleanup Script
.DESCRIPTION
    Performs safe, recurring maintenance:
      - Clears temp files (user + system, older than 3 days)
      - Cleans Windows Update download cache
      - Cleans Delivery Optimization cache
      - Clears thumbnail cache
      - Runs DISM component store cleanup
      - Optimizes drives (TRIM for SSD / defrag for HDD)
      - Flushes DNS cache
      - Runs SFC integrity check (monthly)
      - Reports disk space before/after with savings

    SAFE: Does NOT disable services, modify startup, or change system settings.
    Everything deleted is genuinely temporary/cached data.
.PARAMETER DryRun
    Show what would be cleaned without actually deleting anything.
.EXAMPLE
    .\WinMaintenance.ps1
    .\WinMaintenance.ps1 -DryRun
#>

param(
    [switch]$DryRun
)

# ============================================================
#  CONFIG
# ============================================================
$LogDir  = Join-Path $PSScriptRoot "logs"
$LogFile = Join-Path $LogDir "maintenance_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
$TempFileAgeDays = 3   # Only delete temp files older than this

# ============================================================
#  HELPER FUNCTIONS
# ============================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "OK"      { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry -ForegroundColor Cyan }
    }
}

function Format-Size ([long]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Remove-OldFiles {
    param(
        [string]$Path,
        [int]$OlderThanDays,
        [string]$Filter = "*"
    )
    if (-not (Test-Path $Path)) { return 0 }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $files  = Get-ChildItem -Path $Path -Filter $Filter -Recurse -Force -ErrorAction SilentlyContinue |
              Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff }
    $size   = ($files | Measure-Object -Property Length -Sum).Sum
    if ($size -eq $null) { $size = 0 }
    if (-not $DryRun -and $files) {
        $files | Remove-Item -Force -ErrorAction SilentlyContinue
        # Clean empty subdirectories
        Get-ChildItem -Path $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { @(Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return [long]$size
}

# ============================================================
#  MAIN
# ============================================================
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log "=========================================="
Write-Log "  WINDOWS MAINTENANCE $(if ($DryRun) {'[DRY RUN]'})"
Write-Log "=========================================="
Write-Log "Computer : $env:COMPUTERNAME"
Write-Log "User     : $env:USERNAME"
Write-Log "OS       : $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)"
Write-Log ""

# --- Snapshot disk space BEFORE ---
$drivesBefore = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{N='FreeGB'; E={[math]::Round($_.FreeSpace/1GB,2)}},
        @{N='TotalGB';E={[math]::Round($_.Size/1GB,2)}}
Write-Log "Disk space BEFORE cleanup:"
foreach ($d in $drivesBefore) {
    Write-Log "  $($d.DeviceID)  Free: $($d.FreeGB) GB / $($d.TotalGB) GB"
}
Write-Log ""

$totalCleaned = [long]0

# ----- 1. User Temp Files -----
Write-Log "[1/9] Clearing user temp files (>$TempFileAgeDays days old)..."
$paths = @($env:TEMP, "$env:LOCALAPPDATA\Temp") | Select-Object -Unique
foreach ($p in $paths) {
    $cleaned = Remove-OldFiles -Path $p -OlderThanDays $TempFileAgeDays
    $totalCleaned += $cleaned
    Write-Log "       $(Format-Size $cleaned) from $p"
}

# ----- 2. Windows Temp -----
Write-Log "[2/9] Clearing Windows\Temp (>$TempFileAgeDays days old)..."
$cleaned = Remove-OldFiles -Path "$env:SystemRoot\Temp" -OlderThanDays $TempFileAgeDays
$totalCleaned += $cleaned
Write-Log "       $(Format-Size $cleaned)"

# ----- 3. Windows Update Cache -----
Write-Log "[3/9] Clearing Windows Update download cache..."
$wuPath = "$env:SystemRoot\SoftwareDistribution\Download"
if (Test-Path $wuPath) {
    $size = (Get-ChildItem $wuPath -Recurse -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    if ($size -eq $null) { $size = 0 }
    if (-not $DryRun) {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Get-ChildItem $wuPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction SilentlyContinue
    }
    $totalCleaned += $size
    Write-Log "       $(Format-Size $size)"
}

# ----- 4. Delivery Optimization Cache -----
Write-Log "[4/9] Clearing Delivery Optimization cache..."
if (-not $DryRun) {
    # Cmdlet is in the DeliveryOptimization module (Windows 10 1703+). Its verb is
    # "Delete" (an unapproved PS verb), so PowerShell will warn on import — that's
    # normal. We guard with Get-Command to skip gracefully on older SKUs where the
    # module is absent (e.g. some LTSC and IoT editions).
    if (Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue) {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Write-Log "       Cache cleared" "OK"
        } catch {
            Write-Log "       Skipped (empty or locked): $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Log "       Cmdlet not available on this Windows build. Skipped." "INFO"
    }
}

# ----- 5. Thumbnail Cache -----
Write-Log "[5/9] Clearing thumbnail cache..."
$thumbPath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
if (Test-Path $thumbPath) {
    $thumbFiles = Get-ChildItem $thumbPath -Filter "thumbcache_*.db" -Force -ErrorAction SilentlyContinue
    $size = ($thumbFiles | Measure-Object -Property Length -Sum).Sum
    if ($size -eq $null) { $size = 0 }
    if (-not $DryRun -and $thumbFiles) {
        $thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $totalCleaned += $size
    Write-Log "       $(Format-Size $size)"
}

# ----- 6. Flush DNS Cache -----
Write-Log "[6/9] Flushing DNS cache..."
if (-not $DryRun) {
    $null = ipconfig /flushdns 2>&1
    Write-Log "       DNS cache flushed" "OK"
}

# ----- 7. DISM Component Cleanup -----
Write-Log "[7/9] DISM component store cleanup (this may take a few minutes)..."
if (-not $DryRun) {
    try {
        $null = DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1
        Write-Log "       Component cleanup completed" "OK"
    } catch {
        Write-Log "       DISM cleanup had warnings: $($_.Exception.Message)" "WARN"
    }
}

# ----- 8. Optimize Drives -----
Write-Log "[8/9] Optimizing drives..."
if (-not $DryRun) {
    $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
    foreach ($vol in $volumes) {
        $letter = $vol.DriveLetter
        Write-Log "       Optimizing $($letter):..."
        try {
            Optimize-Volume -DriveLetter $letter -ErrorAction Stop
            $mediaType = (Get-PhysicalDisk | Select-Object -First 1).MediaType
            Write-Log "       $($letter): optimized ($mediaType)" "OK"
        } catch {
            Write-Log "       $($letter): $($_.Exception.Message)" "WARN"
        }
    }
}

# ----- 9. System File Checker (monthly) -----
$sfcMarker = Join-Path $LogDir ".last_sfc_run"
$runSfc = $true
if (Test-Path $sfcMarker) {
    $lastRun = (Get-Item $sfcMarker).LastWriteTime
    if ($lastRun -gt (Get-Date).AddDays(-30)) {
        $runSfc = $false
    }
}
if ($runSfc -and -not $DryRun) {
    Write-Log "[9/9] Running System File Checker (monthly)..."
    $sfcOutput = sfc /scannow 2>&1
    Set-Content -Path $sfcMarker -Value (Get-Date) -ErrorAction SilentlyContinue
    if ($sfcOutput -match "did not find any integrity violations") {
        Write-Log "       No integrity issues found" "OK"
    } else {
        Write-Log "       SFC completed - check log for details" "WARN"
    }
} else {
    Write-Log "[9/9] SFC skipped (ran within last 30 days)"
}

# ----- Cleanup old maintenance logs (keep last 10) -----
$oldLogs = Get-ChildItem $LogDir -Filter "maintenance_*.log" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -Skip 10
if ($oldLogs) {
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Log "Cleaned $($oldLogs.Count) old log files"
}

# ============================================================
#  SUMMARY
# ============================================================
$sw.Stop()
$drivesAfter = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID, @{N='FreeGB';E={[math]::Round($_.FreeSpace/1GB,2)}}

Write-Log ""
Write-Log "=========================================="
Write-Log "  SUMMARY" "OK"
Write-Log "=========================================="
Write-Log "Files cleaned  : $(Format-Size $totalCleaned)" "OK"
Write-Log "Time elapsed   : $($sw.Elapsed.ToString('mm\:ss'))" "OK"
Write-Log ""
Write-Log "Disk space AFTER cleanup:"
foreach ($d in $drivesAfter) {
    $before = ($drivesBefore | Where-Object { $_.DeviceID -eq $d.DeviceID }).FreeGB
    $gained = [math]::Round($d.FreeGB - $before, 2)
    $arrow  = if ($gained -gt 0) { "(+$gained GB)" } else { "(no change)" }
    Write-Log "  $($d.DeviceID)  Free: $($d.FreeGB) GB $arrow" "OK"
}
Write-Log ""
Write-Log "Log saved to: $LogFile"
Write-Log "==========================================" "OK"
