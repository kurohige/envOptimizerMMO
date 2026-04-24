#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up Windows Task Scheduler to run WinMaintenance.ps1 automatically.
.DESCRIPTION
    Creates a scheduled task that runs the maintenance script weekly.
    - Runs every Sunday at 3:00 AM
    - If the PC is off/asleep, runs at the next opportunity
    - Runs with highest privileges (required for cleanup)
    - Won't wake the computer from sleep
.PARAMETER Day
    Day of week to run. Default: Sunday
.PARAMETER Time
    Time to run (24h format). Default: 03:00
.PARAMETER Remove
    Remove the scheduled task instead of creating it.
.EXAMPLE
    .\Setup-Scheduler.ps1                     # Default: Sunday 3 AM
    .\Setup-Scheduler.ps1 -Day Saturday -Time "04:00"
    .\Setup-Scheduler.ps1 -Remove
#>

param(
    [ValidateSet("Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday")]
    [string]$Day = "Sunday",

    [string]$Time = "03:00",

    [switch]$Remove
)

$TaskName = "WinOptimizer - Weekly Maintenance"
$TaskPath = "\WinOptimizer\"

# ----- Remove Mode -----
if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
        Write-Host "Scheduled task removed successfully." -ForegroundColor Green
    } catch {
        Write-Host "Task not found or already removed." -ForegroundColor Yellow
    }
    exit 0
}

# ----- Create Task -----
$scriptPath = Join-Path $PSScriptRoot "WinMaintenance.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: WinMaintenance.ps1 not found at: $scriptPath" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setting up Scheduled Maintenance"       -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Script : $scriptPath"
Write-Host "  Schedule: Every $Day at $Time"
Write-Host ""

# Build the scheduled task
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false `
    -WakeToRun:$false `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew `
    -Priority 7

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Remove existing if present
Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue

# Register the task
Register-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath $TaskPath `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Weekly Windows maintenance: temp cleanup, drive optimization, DISM cleanup, SFC check. Safe and non-disruptive." |
    Out-Null

Write-Host "  Scheduled task created!" -ForegroundColor Green
Write-Host ""
Write-Host "  Task Name : $TaskPath$TaskName"
Write-Host "  Schedule  : Every $Day at $Time"
Write-Host "  Catch-up  : Yes (runs next boot if missed)"
Write-Host "  Wake PC   : No"
Write-Host "  Timeout   : 1 hour max"
Write-Host ""
Write-Host "  To verify: Open Task Scheduler > WinOptimizer" -ForegroundColor DarkGray
Write-Host "  To remove: .\Setup-Scheduler.ps1 -Remove" -ForegroundColor DarkGray
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
