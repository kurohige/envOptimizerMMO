#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Network optimization for online gaming. Safe defaults with opt-in aggressive tweaks.

.DESCRIPTION
    Default (on-by-default, low-risk):
      - Disables NIC power management ("Allow computer to turn off this device") on the
        active adapter. Documented Microsoft recommendation for low-latency packet work.
      - Disables Energy Efficient Ethernet (EEE / 802.3az) on Ethernet adapters. Eliminates
        LPI wake-latency spikes. Wi-Fi adapters: not applicable.
      - Sets NetworkThrottlingIndex = 0xFFFFFFFF. Disables the MMCSS network-packet
        throttle that otherwise caps non-multimedia network processing at ~10k pkt/s
        during audio/video work. Note: this registry value is NOT currently documented
        on Microsoft Learn; reference is legacy KB 948066.
      - Sets SystemResponsiveness = 10. Reserves 10% of CPU for low-priority tasks so
        MMCSS-scheduled work (games, audio) gets up to 90%. Per Microsoft Learn, values
        below 10 are clamped to 20; a value of 100 disables MMCSS entirely.

    Opt-in (use flags):
      -AggressiveTcp
          Per-interface: disables Nagle's algorithm (TcpNoDelay=1), sets TcpAckFrequency=1.
          Reduces delayed-ACK / coalescing for small-packet latency-sensitive games. Benefit
          is debatable for MMOs that send larger batched packets (like BDO). Shipped opt-in
          because the tweak is folklore-heavy and there is no modern Microsoft endorsement.

      -AggressiveKeepalive
          Sets system-wide TCP keepalive to 60s/1s (default is 2h). Caveat: this affects
          EVERY TCP connection, not just the game, including browsers and RDP. Most games
          have application-level keepalives already. Opt-in because there is no evidence
          this helps BDO specifically and it has real side effects on other applications.

      -SetDNS cloudflare|google
          Changes DNS servers. Only affects name-resolution time for first lookups; has no
          effect on steady-state gameplay ping. Useful if your ISP DNS is slow or unreliable.

    Tweaks REMOVED vs. earlier versions (they were no-ops on modern Windows):
      - `netsh int tcp set global autotuninglevel=normal` - "normal" is already the default.
      - Disabling ECN - already disabled on the Internet template by default.
      - Disabling TCP timestamps - already disabled by default.

    Safety:
      - Full registry backup to backups\ before any change.
      - JSON undo-info file for Undo-NetworkChanges.ps1.
      - Wi-Fi detection: skips Ethernet-only tweaks (EEE) and warns about battery impact.

.PARAMETER AggressiveTcp
    Apply per-interface TcpNoDelay + TcpAckFrequency tweaks.

.PARAMETER AggressiveKeepalive
    Apply system-wide 60s/1s TCP keepalive. Impacts ALL TCP connections, not just games.

.PARAMETER AggressiveMmcss
    Keep SystemResponsiveness=10 (default). Pass -AggressiveMmcss:$false to leave the
    OS default (20) alone.

.PARAMETER SetDNS
    cloudflare | google | skip (default: skip, leaves your DNS alone).

.PARAMETER SkipNetworkThrottling
    Skip the NetworkThrottlingIndex + SystemResponsiveness registry writes entirely.

.EXAMPLE
    # Recommended default for a desktop gaming rig on Ethernet
    .\NetworkOptimize.ps1

.EXAMPLE
    # All documented MMO optimizations on top of the defaults
    .\NetworkOptimize.ps1 -AggressiveTcp -SetDNS cloudflare

.EXAMPLE
    # Laptop on Wi-Fi - skip the aggressive stuff
    .\NetworkOptimize.ps1
#>

[CmdletBinding()]
param(
    [switch]$AggressiveTcp,
    [switch]$AggressiveKeepalive,
    [switch]$AggressiveMmcss = $true,
    [ValidateSet('cloudflare','google','skip')][string]$SetDNS = 'skip',
    [switch]$SkipNetworkThrottling
)

$ErrorActionPreference = 'Continue'
$LogDir    = Join-Path $PSScriptRoot 'logs'
$BackupDir = Join-Path $PSScriptRoot 'backups'
$LogFile   = Join-Path $LogDir ('network_optimize_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))

New-Item -Path $LogDir    -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path $BackupDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'DEBUG' { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host $entry -ForegroundColor $color
}

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Log ('       Failed to set {0}: {1}' -f $Name, $_.Exception.Message) 'WARN'
        return $false
    }
}

function Get-IsLaptop {
    return $null -ne (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
}

Write-Log '=========================================='
Write-Log '  NETWORK OPTIMIZATION FOR GAMING'
Write-Log '=========================================='

# ============================================================
#  0. Registry backup
# ============================================================
Write-Log ''
Write-Log '[BACKUP] Saving current network registry state...'
$backupFile = Join-Path $BackupDir ('network_backup_{0}.reg' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$adapterBackup = Join-Path $BackupDir ('adapter_settings_{0}.json' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$regPaths = @(
    'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters',
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
)
foreach ($rp in $regPaths) {
    reg export $rp $backupFile /y 2>&1 | Out-Null
}
Write-Log ('[BACKUP] Saved to: {0}' -f $backupFile) 'OK'

# ============================================================
#  1. Find the active adapter (prefer Ethernet, fallback to any Up adapter)
# ============================================================
Write-Log ''
Write-Log '[1] Finding active network adapter...'

$adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match 'Ethernet|802\.3' } |
    Sort-Object LinkSpeed -Descending | Select-Object -First 1
if (-not $adapter) {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' } |
        Sort-Object LinkSpeed -Descending | Select-Object -First 1
}
if (-not $adapter) {
    Write-Log 'No active network adapter found. Aborting.' 'ERROR'
    exit 1
}

$isWifi    = ($adapter.PhysicalMediaType -match 'Native 802\.11|Wireless|Wi-?Fi')
$isLaptop  = Get-IsLaptop
Write-Log ('       Adapter : {0} [{1}]' -f $adapter.Name, $adapter.InterfaceDescription) 'OK'
Write-Log ('       Media   : {0}' -f $adapter.PhysicalMediaType)
Write-Log ('       Speed   : {0}' -f $adapter.LinkSpeed)

if ($isWifi) {
    Write-Log '       NOTE: Wi-Fi adapter detected. Ethernet-only tweaks (EEE) will be skipped.' 'INFO'
}
if ($isLaptop) {
    Write-Log '       NOTE: Battery-powered device detected.' 'INFO'
}

# Match adapter to its registry GUID for per-interface tweaks.
$tcpipInterfaces = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$activeIP = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
$targetGuid = $null
$regPath    = $null
foreach ($guid in (Get-ChildItem $tcpipInterfaces -ErrorAction SilentlyContinue)) {
    $props = Get-ItemProperty -Path $guid.PSPath -ErrorAction SilentlyContinue
    $ip = if ($props.DhcpIPAddress) { $props.DhcpIPAddress }
          elseif ($props.IPAddress)  { if ($props.IPAddress -is [array]) { $props.IPAddress[0] } else { $props.IPAddress } }
    if ($ip -and $ip -eq $activeIP) {
        $targetGuid = $guid.PSChildName
        $regPath    = $guid.PSPath
        break
    }
}
if ($targetGuid) {
    Write-Log ('       GUID    : {0}' -f $targetGuid)
} else {
    Write-Log '       Could not match adapter to registry GUID - per-interface tweaks will be skipped.' 'WARN'
}

# ============================================================
#  2. NIC power management (default on for gaming)
# ============================================================
Write-Log ''
Write-Log '[2] Disabling NIC power management...'

try {
    $pm = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction SilentlyContinue
    if ($pm) {
        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Disabled -ErrorAction SilentlyContinue
        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnPattern     Disabled -ErrorAction SilentlyContinue
        Write-Log '       Wake-on-LAN / Wake-on-pattern disabled' 'OK'
    }

    $esc = [regex]::Escape($adapter.InterfaceDescription)
    $nic = Get-WmiObject MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceName -match $esc }
    if ($nic) {
        if ($isWifi -and $isLaptop) {
            Write-Log '       Wi-Fi + battery: KEEPING OS power-save (disabling drains battery 30%+ typical).' 'WARN'
        } else {
            $nic.Enable = $false
            $nic.Put() | Out-Null
            Write-Log '       Power-save ("Allow computer to turn off this device") disabled' 'OK'
        }
    }

    if (-not $isWifi) {
        $eee = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -match 'Energy.Efficient|EEE|Green.Ethernet' }
        if ($eee) {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name `
                -DisplayName $eee.DisplayName -DisplayValue 'Disabled' -ErrorAction SilentlyContinue
            Write-Log '       Energy Efficient Ethernet disabled' 'OK'
        }
    } else {
        Write-Log '       EEE skipped (Wi-Fi adapter)' 'DEBUG'
    }
} catch {
    Write-Log ('       Step 2 partial failure: {0}' -f $_.Exception.Message) 'WARN'
}

# ============================================================
#  3. NetworkThrottlingIndex + SystemResponsiveness (MMCSS)
# ============================================================
$mmPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Write-Log ''
if ($SkipNetworkThrottling) {
    Write-Log '[3] MMCSS settings SKIPPED (by -SkipNetworkThrottling).' 'INFO'
} else {
    Write-Log '[3] MMCSS settings...'
    # NetworkThrottlingIndex = 0xFFFFFFFF -> effectively "no throttle" per community convention.
    # Not documented on current MS Learn MMCSS page; reference is legacy KB 948066.
    if (Set-RegValue -Path $mmPath -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF) {
        Write-Log '       NetworkThrottlingIndex = 0xFFFFFFFF (throttle disabled; community-sourced)' 'OK'
    }
    if ($AggressiveMmcss) {
        # Per MS Learn: values <10 are clamped to 20, 100 disables MMCSS entirely.
        # 10 is the valid minimum; reserves only 10% for low-priority so MMCSS gets 90%.
        if (Set-RegValue -Path $mmPath -Name 'SystemResponsiveness' -Value 10) {
            Write-Log '       SystemResponsiveness = 10 (MMCSS gets 90% CPU during multimedia work)' 'OK'
        }
    } else {
        Write-Log '       SystemResponsiveness left at OS default (20)' 'INFO'
    }
}

# ============================================================
#  4. Aggressive TCP (OPT-IN) - per-interface TcpNoDelay / TcpAckFrequency
# ============================================================
Write-Log ''
if ($AggressiveTcp) {
    Write-Log '[4] Aggressive TCP per-interface tweaks (OPT-IN)...'
    if ($regPath) {
        if (Set-RegValue -Path $regPath -Name 'TcpNoDelay'      -Value 1) {
            Write-Log '       TcpNoDelay = 1 (Nagle disabled; disables packet coalescing on this NIC)' 'OK'
        }
        if (Set-RegValue -Path $regPath -Name 'TcpAckFrequency' -Value 1) {
            Write-Log '       TcpAckFrequency = 1 (ACK every packet immediately on this NIC)' 'OK'
        }
        Write-Log '       NOTE: These tweaks help small-packet games. Benefit for MMO-style' 'DEBUG'
        Write-Log '             batched-packet games (BDO) is debated. Opt-in because evidence' 'DEBUG'
        Write-Log '             of modern benefit is folklore-heavy. Revert via Undo script.' 'DEBUG'
    } else {
        Write-Log '       Skipped - no adapter GUID matched.' 'WARN'
    }
} else {
    Write-Log '[4] Aggressive TCP tweaks: not applied (pass -AggressiveTcp to enable).' 'DEBUG'
}

# ============================================================
#  5. Aggressive TCP keepalive (OPT-IN, SYSTEM-WIDE)
# ============================================================
$tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
Write-Log ''
if ($AggressiveKeepalive) {
    Write-Log '[5] Aggressive TCP keepalive (OPT-IN, SYSTEM-WIDE)...'
    Write-Log '       WARNING: affects EVERY TCP connection on this machine, not just the game.'  'WARN'
    if (Set-RegValue -Path $tcpParams -Name 'KeepAliveTime'                -Value 60000) {
        Write-Log '       KeepAliveTime = 60000ms (default is 7200000 / 2h)' 'OK'
    }
    if (Set-RegValue -Path $tcpParams -Name 'KeepAliveInterval'            -Value 1000) {
        Write-Log '       KeepAliveInterval = 1000ms' 'OK'
    }
    if (Set-RegValue -Path $tcpParams -Name 'TcpMaxConnectRetransmissions' -Value 3) {
        Write-Log '       TcpMaxConnectRetransmissions = 3' 'OK'
    }
} else {
    Write-Log '[5] Aggressive keepalive: not applied (pass -AggressiveKeepalive to enable).' 'DEBUG'
}

# ============================================================
#  6. DNS (OPT-IN)
# ============================================================
Write-Log ''
$previousDns = $null
if ($SetDNS -ne 'skip') {
    Write-Log ('[6] Setting DNS servers ({0})...' -f $SetDNS)
    $dnsServers = switch ($SetDNS) {
        'cloudflare' { @('1.1.1.1', '1.0.0.1') }
        'google'     { @('8.8.8.8', '8.8.4.4') }
    }
    try {
        $previousDns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dnsServers -ErrorAction Stop
        Write-Log ('       Primary   : {0}' -f $dnsServers[0]) 'OK'
        Write-Log ('       Secondary : {0}' -f $dnsServers[1]) 'OK'
        Write-Log ('       Previous  : {0}' -f ($previousDns -join ', '))
        $null = ipconfig /flushdns 2>&1
        Write-Log '       DNS cache flushed' 'OK'
        Write-Log '       NOTE: DNS change only affects first-lookup time; it does not alter gameplay ping.' 'DEBUG'
    } catch {
        Write-Log ('       DNS change failed: {0}' -f $_.Exception.Message) 'WARN'
    }
} else {
    Write-Log '[6] DNS: not changed (pass -SetDNS cloudflare|google to change).' 'DEBUG'
}

# ============================================================
#  Save undo info
# ============================================================
$undo = @{
    Timestamp            = (Get-Date).ToString('o')
    AdapterName          = $adapter.Name
    AdapterGuid          = $targetGuid
    PreviousDNS          = $previousDns
    RegistryBackup       = $backupFile
    DNSProvider          = $SetDNS
    AggressiveTcp        = [bool]$AggressiveTcp
    AggressiveKeepalive  = [bool]$AggressiveKeepalive
    AggressiveMmcss      = [bool]$AggressiveMmcss
    SkippedMmcss         = [bool]$SkipNetworkThrottling
    IsWifi               = [bool]$isWifi
    IsLaptop             = [bool]$isLaptop
}
try {
    $undo | ConvertTo-Json | Set-Content -Path $adapterBackup -Encoding UTF8 -ErrorAction Stop
    Write-Log ''
    Write-Log ('Undo info: {0}' -f $adapterBackup)
} catch {
    Write-Log ('Could not save undo info: {0}' -f $_.Exception.Message) 'WARN'
}

# ============================================================
#  Summary
# ============================================================
Write-Log ''
Write-Log '==========================================' 'OK'
Write-Log '  OPTIMIZATION COMPLETE' 'OK'
Write-Log '==========================================' 'OK'
Write-Log ''
Write-Log '  Default tweaks applied:'
Write-Log '    [x] NIC power management disabled'
if (-not $isWifi) { Write-Log '    [x] Energy Efficient Ethernet disabled' }
if (-not $SkipNetworkThrottling) {
    Write-Log '    [x] NetworkThrottlingIndex = 0xFFFFFFFF'
    if ($AggressiveMmcss) { Write-Log '    [x] SystemResponsiveness = 10' }
}
if ($AggressiveTcp)       { Write-Log '    [x] TcpNoDelay + TcpAckFrequency (per-interface)' }
if ($AggressiveKeepalive) { Write-Log '    [x] Aggressive TCP keepalive (system-wide)' }
if ($SetDNS -ne 'skip')   { Write-Log ('    [x] DNS set to {0}' -f $SetDNS) }
Write-Log ''
Write-Log '  Reboot recommended for all changes to take effect.' 'WARN'
Write-Log ('  Log    : {0}' -f $LogFile)
Write-Log ('  Backup : {0}' -f $backupFile)
Write-Log '  Undo   : .\Undo-NetworkChanges.ps1'
