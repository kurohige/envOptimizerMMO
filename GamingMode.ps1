#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-session optimizer. Temporary, reversible tweaks for a gaming session.

.DESCRIPTION
    Applies safe defaults before gaming, reports system state, optionally runs
    NetworkOptimize. Run with -Stop after the session to revert.

    Defaults (low-risk, reversible):
      - Power plan -> High Performance.
      - Working-set trim of non-critical background processes (frees RAM).
      - DNS cache flush.
      - Connection quality test (ping/jitter to DNS + default gateway).
      - Advisory list of resource-heavy apps still running.
      - Informational reports:
          VBS / HVCI (Memory Integrity) status - documented 3-8% CPU cost in
          games; the script only REPORTS this, it does not toggle it (security
          tradeoff belongs to the user).

    Opt-in flags:
      -Ultimate
          Use Ultimate Performance power plan instead of High Performance.
          REFUSED if the system has a battery present (laptop), since this
          plan disables processor idle states and causes thermal throttling
          and battery drain on mobile hardware.

      -DisableMemoryCompression
          Runs Disable-MMAgent -MemoryCompression. Trades a small CPU saving
          for increased paging under memory pressure. Microsoft documents the
          cmdlet but publishes no RAM-capacity threshold; community practice
          advises against this on <16 GB systems. Reverted on -Stop with
          Enable-MMAgent.

      -DisablePciLinkPower
          Sets PCI Express -> Link State Power Management to Off on the
          active power plan. Microsoft Learn warns: "System administrators
          should not change the power plan personality settings." Apply only
          if you have diagnosed latency spikes traceable to PCIe ASPM.

      -GameMode enable | disable | keep     (default: keep)
          Windows Game Mode toggle. The script leaves it alone by default
          because Microsoft does not publish behavior differences between
          Windows 10 and 11 that would drive a single recommendation. Pass
          -GameMode enable on Windows 11 if you want it ensured on, or
          -GameMode disable on Windows 10 if community reports of background-
          app starvation match your setup.

    Passthrough to NetworkOptimize.ps1 (run in the same folder):
      -SkipNetwork, -DNS (cloudflare|google|skip), -AggressiveTcp

.PARAMETER Stop
    Revert everything this script changed in a previous start-mode run.
#>

[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Ultimate,
    [switch]$DisableMemoryCompression,
    [switch]$DisablePciLinkPower,
    [ValidateSet('enable','disable','keep')][string]$GameMode = 'keep',
    [switch]$SkipNetwork,
    [ValidateSet('cloudflare','google','skip')][string]$DNS = 'skip',
    [switch]$AggressiveTcp
)

$stateFile = Join-Path $PSScriptRoot 'logs\.gaming_mode_state'
New-Item -Path (Join-Path $PSScriptRoot 'logs') -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

# ------------------------------------------------------------------
#  Formatting
# ------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR')][string]$Level = 'INFO')
    switch ($Level) {
        'OK'   { Write-Host ('  [+] {0}' -f $Message) -ForegroundColor Green }
        'WARN' { Write-Host ('  [!] {0}' -f $Message) -ForegroundColor Yellow }
        'ERR'  { Write-Host ('  [-] {0}' -f $Message) -ForegroundColor Red }
        default{ Write-Host ('  [>] {0}' -f $Message) -ForegroundColor Cyan }
    }
}

# ------------------------------------------------------------------
#  P/Invoke for EmptyWorkingSet
# ------------------------------------------------------------------
Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class NativeMemory {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
'@

# ------------------------------------------------------------------
#  Utility: detect battery / laptop
# ------------------------------------------------------------------
function Get-IsLaptop {
    return $null -ne (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
}

# ------------------------------------------------------------------
#  Power plan: Ultimate vs High Performance
# ------------------------------------------------------------------
$UltimateGuid  = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGuid  = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BalancedGuid  = '381b4222-f694-41f0-9685-ff5bb260df2e'
# PCI Express subgroup and ASPM setting GUIDs (verified on MS Learn).
$PciExpressSubgroup  = '501a4d13-42af-4429-9fd1-a8218c268e20'
$PciLinkPowerSetting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'

# ============================================================
#  STOP MODE
# ============================================================
if ($Stop) {
    Write-Host ''
    Write-Host '  GAMING MODE OFF' -ForegroundColor Yellow
    Write-Host '  ===============' -ForegroundColor Yellow
    Write-Host ''

    $state = $null
    if (Test-Path $stateFile) {
        try { $state = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { }
    }

    # Power plan
    if ($state -and $state.PreviousPowerPlanGuid) {
        powercfg /setactive $state.PreviousPowerPlanGuid | Out-Null
        Write-Status ('Power plan restored to previous GUID {0}' -f $state.PreviousPowerPlanGuid) 'OK'
    } else {
        powercfg /setactive $BalancedGuid | Out-Null
        Write-Status 'Power plan set to Balanced (no prior state found)' 'OK'
    }

    # Memory compression
    if ($state -and $state.MemoryCompressionWasEnabled -and $state.DisabledMemoryCompression) {
        try {
            Enable-MMAgent -MemoryCompression -ErrorAction Stop
            Write-Status 'Memory Compression re-enabled' 'OK'
        } catch {
            Write-Status ('Could not re-enable memory compression: {0}' -f $_.Exception.Message) 'WARN'
        }
    }

    # PCI Link State Power Management
    if ($state -and $state.PciLinkPowerWasSet -and $null -ne $state.PreviousPciLinkPowerAC) {
        powercfg /setacvalueindex SCHEME_CURRENT $PciExpressSubgroup $PciLinkPowerSetting $state.PreviousPciLinkPowerAC | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT $PciExpressSubgroup $PciLinkPowerSetting $state.PreviousPciLinkPowerDC | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Write-Status 'PCI Link State Power Management restored' 'OK'
    }

    # Game Mode
    if ($state -and $state.GameModeChanged) {
        $gkey = 'HKCU:\Software\Microsoft\GameBar'
        if (Test-Path $gkey) {
            Set-ItemProperty -Path $gkey -Name 'AutoGameModeEnabled' -Value $state.PreviousGameMode -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Status 'Game Mode restored to previous setting' 'OK'
        }
    }

    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  Session ended. GG.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# ============================================================
#  START MODE
# ============================================================
Write-Host ''
Write-Host '  =====================================' -ForegroundColor Magenta
Write-Host '        GAMING MODE ACTIVATED'           -ForegroundColor Magenta
Write-Host '  =====================================' -ForegroundColor Magenta
Write-Host ''

$state = @{
    PreviousPowerPlanGuid       = $null
    DisabledMemoryCompression   = $false
    MemoryCompressionWasEnabled = $false
    PciLinkPowerWasSet          = $false
    PreviousPciLinkPowerAC      = $null
    PreviousPciLinkPowerDC      = $null
    GameModeChanged             = $false
    PreviousGameMode            = $null
}

# ----- Previous power plan snapshot -----
$currentPlanLine = (powercfg /getactivescheme) -replace '.*:\s*',''
$currentPlanGuid = ($currentPlanLine -split '\s+')[0]
$state.PreviousPowerPlanGuid = $currentPlanGuid

# ----- 1. Power plan -----
Write-Host '  [Power]' -ForegroundColor White
$isLaptop = Get-IsLaptop

if ($Ultimate) {
    if ($isLaptop) {
        Write-Status 'Ultimate Performance refused: battery detected on this system.' 'ERR'
        Write-Status 'Ultimate disables CPU idle states and causes thermal throttling + battery drain on laptops.' 'ERR'
        Write-Status 'Falling back to High Performance.' 'WARN'
        $Ultimate = $false
    } else {
        $plans = powercfg /list 2>&1
        $hasUlt = ($plans -match $UltimateGuid)
        if (-not $hasUlt) { powercfg /duplicatescheme $UltimateGuid 2>&1 | Out-Null }
        powercfg /setactive $UltimateGuid | Out-Null
        Write-Status 'Power plan: Ultimate Performance' 'OK'
    }
}

if (-not $Ultimate) {
    powercfg /setactive $HighPerfGuid | Out-Null
    Write-Status 'Power plan: High Performance' 'OK'
}

# ----- 2. VBS / HVCI status (informational only) -----
Write-Host ''
Write-Host '  [Security feature CPU cost]' -ForegroundColor White
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    $vbsRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
    $hvciRunning = $false
    if ($dg.SecurityServicesRunning) { $hvciRunning = ($dg.SecurityServicesRunning -contains 2) }

    if ($vbsRunning) {
        Write-Status 'VBS (Virtualization-Based Security): RUNNING - documented 3-8% CPU cost in games.' 'WARN'
    } else {
        Write-Status 'VBS: not running.' 'OK'
    }
    if ($hvciRunning) {
        Write-Status 'HVCI (Memory Integrity): RUNNING - additional cost on top of VBS.' 'WARN'
        Write-Status '      Toggle at: Settings > Windows Security > Device Security > Core isolation' 'INFO'
        Write-Status '      Tradeoff: disabling improves perf but reduces kernel-driver isolation.' 'INFO'
    }
} catch {
    Write-Status 'VBS/HVCI status unavailable (class not present on this SKU).' 'INFO'
}

# ----- 3. Memory compression (opt-in) -----
if ($DisableMemoryCompression) {
    Write-Host ''
    Write-Host '  [Memory compression]' -ForegroundColor White
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        $state.MemoryCompressionWasEnabled = [bool]$mm.MemoryCompression
        if ($mm.MemoryCompression) {
            Disable-MMAgent -MemoryCompression -ErrorAction Stop
            $state.DisabledMemoryCompression = $true
            Write-Status 'Memory Compression disabled for this session.' 'OK'
            Write-Status 'Tradeoff: reduces CPU overhead from the compressor; increases paging under pressure.' 'INFO'
        } else {
            Write-Status 'Memory Compression was already off. No change.' 'INFO'
        }
    } catch {
        Write-Status ('Could not disable memory compression: {0}' -f $_.Exception.Message) 'WARN'
    }
}

# ----- 4. PCI Express Link State Power Management (opt-in) -----
if ($DisablePciLinkPower) {
    Write-Host ''
    Write-Host '  [PCI Express ASPM]' -ForegroundColor White
    Write-Status 'Microsoft Learn warning: "System administrators should not change the power plan personality settings."' 'WARN'
    try {
        # Read current values so we can restore on -Stop
        $q = powercfg /query SCHEME_CURRENT $PciExpressSubgroup $PciLinkPowerSetting 2>&1 | Out-String
        $acMatch = [regex]::Match($q, 'Current AC.*?0x([0-9A-Fa-f]+)')
        $dcMatch = [regex]::Match($q, 'Current DC.*?0x([0-9A-Fa-f]+)')
        if ($acMatch.Success) { $state.PreviousPciLinkPowerAC = [int]("0x$($acMatch.Groups[1].Value)") }
        if ($dcMatch.Success) { $state.PreviousPciLinkPowerDC = [int]("0x$($dcMatch.Groups[1].Value)") }

        # Set to Off (0) on both AC and DC
        powercfg /setacvalueindex SCHEME_CURRENT $PciExpressSubgroup $PciLinkPowerSetting 0 | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT $PciExpressSubgroup $PciLinkPowerSetting 0 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        $state.PciLinkPowerWasSet = $true
        Write-Status 'PCI Link State Power Management set to Off (AC+DC).' 'OK'
    } catch {
        Write-Status ('PCI Link power change failed: {0}' -f $_.Exception.Message) 'WARN'
    }
}

# ----- 5. Game Mode (explicit toggle only) -----
if ($GameMode -ne 'keep') {
    Write-Host ''
    Write-Host '  [Game Mode]' -ForegroundColor White
    $gkey = 'HKCU:\Software\Microsoft\GameBar'
    if (-not (Test-Path $gkey)) { New-Item -Path $gkey -Force | Out-Null }
    $cur = (Get-ItemProperty -Path $gkey -Name 'AutoGameModeEnabled' -ErrorAction SilentlyContinue).AutoGameModeEnabled
    $state.PreviousGameMode = if ($null -eq $cur) { 1 } else { [int]$cur }
    $newVal = if ($GameMode -eq 'enable') { 1 } else { 0 }
    Set-ItemProperty -Path $gkey -Name 'AutoGameModeEnabled' -Value $newVal -Type DWord -Force
    Set-ItemProperty -Path $gkey -Name 'AllowAutoGameMode'   -Value $newVal -Type DWord -Force -ErrorAction SilentlyContinue
    $state.GameModeChanged = $true
    Write-Status ("Game Mode set to '{0}' (was {1})." -f $GameMode, $state.PreviousGameMode) 'OK'
}

# Persist state NOW so -Stop can revert even if later steps fail
$state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

# ----- 6. Memory snapshot + working-set trim -----
Write-Host ''
Write-Host '  [Memory]' -ForegroundColor White
$os = Get-CimInstance Win32_OperatingSystem
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
Write-Status ("RAM before: {0} GB free / {1} GB total" -f $freeGB, $totalGB)

$protected = @('System','Idle','csrss','smss','wininit','services','lsass','dwm','svchost',
               'fontdrvhost','WUDFHost','NisSrv','MsMpEng')
$trimmed = 0
Get-Process | Where-Object {
    $_.ProcessName -notin $protected -and $_.WorkingSet64 -gt 50MB
} | ForEach-Object {
    try { [NativeMemory]::EmptyWorkingSet($_.Handle) | Out-Null; $trimmed++ } catch { }
}
$os2 = Get-CimInstance Win32_OperatingSystem
$freeGB2 = [math]::Round($os2.FreePhysicalMemory / 1MB, 2)
Write-Status ("RAM after:  {0} GB free  ({1} processes trimmed)" -f $freeGB2, $trimmed) 'OK'

$heavyProcs = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
              ForEach-Object { "{0} ({1:N0} MB)" -f $_.ProcessName, ($_.WorkingSet64 / 1MB) }
Write-Status ("Top memory users: {0}" -f ($heavyProcs -join ', '))

# ----- 7. DNS flush -----
Write-Host ''
Write-Host '  [Network]' -ForegroundColor White
$null = ipconfig /flushdns 2>&1
Write-Status 'DNS cache flushed' 'OK'

# ----- 8. Connection test -----
Write-Host ''
Write-Host '  [Connection test]' -ForegroundColor White
function Invoke-PingTest {
    param([string]$HostName, [int]$Count = 5)
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $lat = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $pinger.Send($HostName, 1000)
            if ($r.Status -eq 'Success') { $lat += $r.RoundtripTime }
        } catch { }
    }
    $pinger.Dispose()
    return $lat
}

$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       Sort-Object RouteMetric | Select-Object -First 1).NextHop
$targets = @(
    @{ Name = 'Cloudflare DNS'; Host = '1.1.1.1' },
    @{ Name = 'Google DNS';     Host = '8.8.8.8' },
    @{ Name = 'Default GW';     Host = $gw }
)
foreach ($t in $targets) {
    if (-not $t.Host) { continue }
    $lat = Invoke-PingTest -HostName $t.Host -Count 5
    if ($lat.Count -gt 0) {
        $avg  = [math]::Round(($lat | Measure-Object -Average).Average, 1)
        $jit  = [math]::Round((($lat | Measure-Object -Maximum).Maximum) - (($lat | Measure-Object -Minimum).Minimum), 1)
        $loss = [math]::Round((1 - $lat.Count / 5) * 100, 0)
        $lvl  = if     ($avg -lt 20 -and $loss -eq 0) { 'OK' }
                elseif ($avg -lt 60 -and $loss -lt 20) { 'WARN' }
                else                                    { 'ERR' }
        $suf  = if ($loss -gt 0) { "  ({0}% packet loss)" -f $loss } else { '' }
        Write-Status ('{0} ({1}): {2}ms avg, {3}ms jitter{4}' -f $t.Name, $t.Host, $avg, $jit, $suf) $lvl
    } else {
        Write-Status ('{0} ({1}): UNREACHABLE' -f $t.Name, $t.Host) 'ERR'
    }
}

# ----- 9. Heavy background app advisory -----
Write-Host ''
Write-Host '  [Background apps]' -ForegroundColor White
$known = @{
    'OneDrive'='OneDrive sync'; 'Teams'='Microsoft Teams'; 'Dropbox'='Dropbox sync'
    'Steam'='Steam client'; 'EpicGamesLauncher'='Epic Games'; 'chrome'='Google Chrome'
    'firefox'='Firefox'; 'msedge'='Microsoft Edge'; 'Discord'='Discord'
    'Spotify'='Spotify'; 'WindowsTerminal'='Windows Terminal'; 'Code'='VS Code'
    'slack'='Slack'; 'zoom'='Zoom'
}
$running = @()
foreach ($p in $known.GetEnumerator()) {
    $pp = Get-Process -Name $p.Key -ErrorAction SilentlyContinue
    if ($pp) {
        $mb = [math]::Round(($pp | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 0)
        $running += '{0} ({1} MB)' -f $p.Value, $mb
    }
}
if ($running) {
    Write-Status 'Resource-heavy apps currently running:' 'WARN'
    foreach ($r in $running) { Write-Host ('       ' + $r) -ForegroundColor Yellow }
    Write-Host '       (Advisory only - this script does not close anything.)' -ForegroundColor DarkGray
} else {
    Write-Status 'No known heavy background apps detected' 'OK'
}

# ----- 10. NetworkOptimize passthrough -----
Write-Host ''
Write-Host '  [Network optimization]' -ForegroundColor White
if ($SkipNetwork) {
    Write-Status 'Skipped (-SkipNetwork).' 'INFO'
} else {
    $netScript = Join-Path $PSScriptRoot 'NetworkOptimize.ps1'
    if (Test-Path $netScript) {
        $netArgs = @{ SetDNS = $DNS }
        if ($AggressiveTcp) { $netArgs['AggressiveTcp'] = $true }
        Write-Status ("Running NetworkOptimize.ps1 -SetDNS $DNS" + $(if ($AggressiveTcp) { ' -AggressiveTcp' } else { '' })) 'INFO'
        Write-Host ''
        & $netScript @netArgs
        Write-Host ''
        Write-Status 'Network optimization complete' 'OK'
    } else {
        Write-Status 'NetworkOptimize.ps1 not found in this folder - skipped.' 'WARN'
    }
}

# ----- Done -----
Write-Host ''
Write-Host '  =====================================' -ForegroundColor Green
Write-Host '        READY TO GAME' -ForegroundColor Green
Write-Host '  =====================================' -ForegroundColor Green
Write-Host ''
Write-Host "  Run '.\GamingMode.ps1 -Stop' when done to revert everything." -ForegroundColor DarkGray
Write-Host ''
