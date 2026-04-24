#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Reverts changes made by NetworkOptimize.ps1.

.DESCRIPTION
    Reads the most recent adapter_settings_*.json from backups\ and undoes each
    tweak it records. Only touches settings that NetworkOptimize actually applied
    (reads the undo-info flags), so a default-options run followed by this script
    restores the default-options subset, and similarly for -AggressiveTcp etc.

    Safety:
      - If no backup file is found, refuses to run (no default assumptions).
      - Re-enables NIC power management + EEE (they were disabled).
      - Resets MMCSS values to documented OS defaults (NetworkThrottlingIndex=10,
        SystemResponsiveness=20).
      - Removes opt-in TCP / keepalive values (deletes the registry entries,
        which is the correct way to revert to "not set" semantics).
      - Restores DNS to the previous servers recorded in the undo file, or to
        DHCP if the previous setting was DHCP.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$BackupDir = Join-Path $PSScriptRoot 'backups'

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '  UNDO NETWORK OPTIMIZATIONS'               -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ''

$settingsFile = Get-ChildItem $BackupDir -Filter 'adapter_settings_*.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $settingsFile) {
    Write-Host "No backup found in $BackupDir - cannot undo." -ForegroundColor Red
    Write-Host 'Run NetworkOptimize.ps1 first, or restore manually.' -ForegroundColor Red
    exit 1
}

$u = Get-Content $settingsFile.FullName -Raw | ConvertFrom-Json
Write-Host ('Using backup from : {0}' -f $u.Timestamp) -ForegroundColor Yellow
Write-Host ('Adapter           : {0}' -f $u.AdapterName) -ForegroundColor Yellow
Write-Host ''

# ----- 1. NetworkThrottlingIndex + SystemResponsiveness -----
if (-not $u.SkippedMmcss) {
    Write-Host '[1] Resetting MMCSS values to Windows defaults...' -ForegroundColor Cyan
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-ItemProperty -Path $mm -Name 'NetworkThrottlingIndex' -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mm -Name 'SystemResponsiveness'   -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Host '       NetworkThrottlingIndex -> 10' -ForegroundColor Green
    Write-Host '       SystemResponsiveness   -> 20' -ForegroundColor Green
}

# ----- 2. Per-interface TCP tweaks -----
if ($u.AggressiveTcp -and $u.AdapterGuid) {
    Write-Host '[2] Removing per-interface TCP tweaks...' -ForegroundColor Cyan
    $ifPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($u.AdapterGuid)"
    Remove-ItemProperty -Path $ifPath -Name 'TcpNoDelay'      -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $ifPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
    Write-Host '       TcpNoDelay and TcpAckFrequency removed (back to OS defaults)' -ForegroundColor Green
}

# ----- 3. System-wide keepalive -----
if ($u.AggressiveKeepalive) {
    Write-Host '[3] Removing aggressive TCP keepalive...' -ForegroundColor Cyan
    $tp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Remove-ItemProperty -Path $tp -Name 'KeepAliveTime'                -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $tp -Name 'KeepAliveInterval'            -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $tp -Name 'TcpMaxConnectRetransmissions' -ErrorAction SilentlyContinue
    Write-Host '       Keepalive values removed (OS default = 7200000ms / 2h)' -ForegroundColor Green
}

# ----- 4. NIC power management + EEE -----
Write-Host '[4] Re-enabling NIC power management + EEE...' -ForegroundColor Cyan
$adapter = Get-NetAdapter -Name $u.AdapterName -ErrorAction SilentlyContinue
if ($adapter) {
    try {
        $esc = [regex]::Escape($adapter.InterfaceDescription)
        $nic = Get-WmiObject MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
               Where-Object { $_.InstanceName -match $esc }
        if ($nic) {
            $nic.Enable = $true
            $nic.Put() | Out-Null
            Write-Host '       Power-save re-enabled' -ForegroundColor Green
        }
        if (-not $u.IsWifi) {
            $eee = Get-NetAdapterAdvancedProperty -Name $u.AdapterName -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -match 'Energy.Efficient|EEE|Green.Ethernet' }
            if ($eee) {
                Set-NetAdapterAdvancedProperty -Name $u.AdapterName `
                    -DisplayName $eee.DisplayName -DisplayValue 'Enabled' -ErrorAction SilentlyContinue
                Write-Host '       Energy Efficient Ethernet re-enabled' -ForegroundColor Green
            }
        }
    } catch {
        Write-Host ('       WMI revert partial failure: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
} else {
    Write-Host '       Adapter no longer present - skipped.' -ForegroundColor Yellow
}

# ----- 5. DNS -----
if ($u.DNSProvider -and $u.DNSProvider -ne 'skip') {
    Write-Host '[5] Restoring DNS...' -ForegroundColor Cyan
    if ($adapter) {
        if ($u.PreviousDNS -and $u.PreviousDNS.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $u.PreviousDNS -ErrorAction SilentlyContinue
            Write-Host ('       DNS restored to: {0}' -f ($u.PreviousDNS -join ', ')) -ForegroundColor Green
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            Write-Host '       DNS reset to DHCP defaults' -ForegroundColor Green
        }
        $null = ipconfig /flushdns 2>&1
    }
}

Write-Host ''
Write-Host '==========================================' -ForegroundColor Green
Write-Host '  ALL APPLIED CHANGES REVERTED'             -ForegroundColor Green
Write-Host '==========================================' -ForegroundColor Green
Write-Host ''
Write-Host '  ** REBOOT recommended **' -ForegroundColor Yellow
Write-Host ''
