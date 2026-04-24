#Requires -Version 5.1
# NOTE: Administrator is required only when actually modifying a process
# (SetProcessAffinityMask on protected processes). -ShowTopology and -DryRun
# work unelevated - useful for inspecting your CPU without risk.
<#
.SYNOPSIS
    Generic CPU-affinity manager for MMO/online games. Profile-driven.

.DESCRIPTION
    Replaces the BDO-specific affinity script with a generalized, topology-aware
    version. Reads game profiles from games.json and applies per-family affinity
    strategies derived from detected CPU topology (P/E cores, AMD CCDs, X3D
    V-Cache die). No hardcoded hex masks - everything is computed at runtime.

    Two operating modes:

      Attach mode (default)
        Waits for the game process to appear, then applies affinity and
        priority. A watchdog reapplies if the game forks child processes or
        EasyAntiCheat resets the mask. Runs until the game exits.

      Launcher-inherit mode (-LaunchGame <path>)
        Starts the launcher EXE with the affinity mask pre-applied via
        `cmd /c start /affinity`. The game process inherits the mask before
        EAC attaches - the canonical BDO-community approach per ACanadianDude's
        guide. Preferred when your anti-cheat blocks post-launch affinity
        changes.

    Safety:
      - Uses SetProcessAffinityMask (available on every Windows since XP).
        CPU Sets ("soft affinity") was considered but requires Win11 build 22000+
        for the mask variant and offers weaker guarantees. Hard affinity is
        consistent with `Start /affinity` and is what EAC expects to see
        inherited.
      - Never sets an empty mask. Never overrides a running process that is
        not in the profile's process-name list. -DryRun reports what would
        happen without touching anything.

.PARAMETER GameId
    Profile id in games.json. Defaults to 'BDO'.

.PARAMETER ProcessName
    Override process name (without .exe). Useful for one-off runs against
    games not in games.json; uses the defaultProfile's strategy.

.PARAMETER Strategy
    Power-user override: apply a specific strategy name instead of the one
    the profile would pick. See _GameProfile.ps1 for the strategy catalog.

.PARAMETER Priority
    Process priority class. Default: Normal. 'High' on an already-affinity-
    limited process is a lot; 'Realtime' is almost always a bad idea and will
    be rejected unless you pass -Force.

.PARAMETER LaunchGame
    Path to the game launcher EXE. If provided, launches it with affinity
    pre-applied via `cmd /c start /affinity <mask>` so the game inherits
    before anti-cheat starts. Recommended for BDO on EAC.

.PARAMETER Steam
    Pass -steam flag to the launcher when using -LaunchGame.

.PARAMETER ShowTopology
    Print detected CPU topology and the computed plan, then exit without
    touching any process. Useful for verifying what the tool sees.

.PARAMETER DryRun
    Compute and print everything but do not modify any process.

.PARAMETER TimeoutSeconds
    How long to wait for the game process to appear in attach mode. Default 300.

.PARAMETER PollMs
    Watchdog polling interval in attach mode. Default 2000.

.PARAMETER LogFile
    Path to a log file. If empty, logs only to console.

.PARAMETER Force
    Allow potentially dangerous priority classes (Realtime).

.EXAMPLE
    # Default: BDO profile, attach mode (wait for BlackDesert64.exe)
    .\Set-GameAffinity.ps1

.EXAMPLE
    # Launcher-inherit mode (preferred for EAC)
    .\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"

.EXAMPLE
    # See what would happen on your CPU without touching anything
    .\Set-GameAffinity.ps1 -ShowTopology

.EXAMPLE
    # Apply to an arbitrary process using the default (conservative) profile
    .\Set-GameAffinity.ps1 -ProcessName notepad -DryRun
#>

[CmdletBinding()]
param(
    [string]$GameId = 'BDO',
    [string]$ProcessName,
    [string]$Strategy,
    [ValidateSet('Realtime','High','AboveNormal','Normal','BelowNormal','Idle')]
    [string]$Priority = 'Normal',
    [string]$LaunchGame,
    [switch]$Steam,
    [switch]$ShowTopology,
    [switch]$DryRun,
    [int]$TimeoutSeconds = 300,
    [int]$PollMs = 2000,
    [string]$LogFile = '',
    [switch]$Force
)

# ------------------------------------------------------------------
#  Dot-source helpers
# ------------------------------------------------------------------
. (Join-Path $PSScriptRoot '_CpuTopology.ps1')
. (Join-Path $PSScriptRoot '_GameProfile.ps1')

# ------------------------------------------------------------------
#  Logging
# ------------------------------------------------------------------
function Write-LogLine {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'DEBUG' { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------
#  Win32 P/Invoke for SetProcessAffinityMask
# ------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'EnvOptimizer.AffinityNative').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace EnvOptimizer {
    public static class AffinityNative {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint desiredAccess, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetProcessAffinityMask(IntPtr h, IntPtr mask);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetProcessAffinityMask(IntPtr h, out IntPtr pMask, out IntPtr sMask);
        public const uint PROCESS_SET_INFORMATION   = 0x0200;
        public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    }
}
'@
}

function Set-ProcessAffinityAndPriority {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][uint64]$Mask,
        [string]$PriorityClass = 'Normal'
    )
    if ($DryRun) {
        Write-LogLine ("DRY RUN: would set PID {0} affinity=0x{1:X} priority={2}" -f $ProcessId, $Mask, $PriorityClass) 'DEBUG'
        return $true
    }

    $access = [EnvOptimizer.AffinityNative]::PROCESS_SET_INFORMATION -bor `
              [EnvOptimizer.AffinityNative]::PROCESS_QUERY_INFORMATION
    $h = [EnvOptimizer.AffinityNative]::OpenProcess($access, $false, [uint32]$ProcessId)
    if ($h -eq [IntPtr]::Zero) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-LogLine ("OpenProcess failed for PID {0}. Win32 error {1} - make sure you're elevated." -f $ProcessId, $err) 'ERROR'
        return $false
    }

    try {
        $ok = [EnvOptimizer.AffinityNative]::SetProcessAffinityMask($h, [IntPtr]([int64]$Mask))
        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-LogLine ("SetProcessAffinityMask failed for PID {0}. Win32 error {1}" -f $ProcessId, $err) 'ERROR'
            return $false
        }
    } finally {
        [void][EnvOptimizer.AffinityNative]::CloseHandle($h)
    }

    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $p.PriorityClass = $PriorityClass
    } catch {
        Write-LogLine ("Could not set priority for PID {0}: {1}" -f $ProcessId, $_.Exception.Message) 'WARN'
    }

    $lps = ConvertFrom-AffinityMask -Mask $Mask
    Write-LogLine ("PID {0}: affinity=0x{1:X} LPs=[{2}] priority={3}" -f `
        $ProcessId, $Mask, ($lps -join ','), $PriorityClass) 'OK'
    return $true
}

# ------------------------------------------------------------------
#  Main
# ------------------------------------------------------------------
Write-LogLine '=== Set-GameAffinity started ==='

# 1. Topology
$topo = Get-CpuTopology
if ($ShowTopology) {
    Show-CpuTopology -Topology $topo
}

# 2. Profile resolution
$profile = Get-GameProfile -GameId $GameId -ProcessName $ProcessName
$effectiveProcessName = if ($ProcessName) { $ProcessName } else { $profile.ProcessName }
if ($effectiveProcessName -and $effectiveProcessName.ToLower().EndsWith('.exe')) {
    $effectiveProcessName = $effectiveProcessName.Substring(0, $effectiveProcessName.Length - 4)
}

Write-LogLine ("Profile      : {0} ({1})" -f $profile.Id, $profile.DisplayName)
Write-LogLine ("Process name : {0}" -f $effectiveProcessName)

# 3. Strategy selection (user override wins)
$strategyName = $null
$family = $null
if ($Strategy) {
    $strategyName = $Strategy
    $family = '(user override)'
} else {
    $sel = Select-StrategyForTopology -Topology $topo -StrategyMap $profile.AffinityStrategy
    $strategyName = $sel.Strategy
    $family       = $sel.Family
}

Write-LogLine ("Topology family: {0}" -f $family)
Write-LogLine ("Strategy     : {0}" -f $strategyName)

# 4. Priority safety check
if ($Priority -eq 'Realtime' -and -not $Force) {
    Write-LogLine 'Refusing to use Realtime priority without -Force. This class can starve the OS and is almost always wrong for games.' 'ERROR'
    exit 2
}

# 5. Compute mask
$mask = Resolve-AffinityMask -Topology $topo -Strategy $strategyName
if ($mask -eq 0) {
    Write-LogLine 'Resolved strategy yields no affinity change (mask=0). Exiting without touching processes.' 'INFO'
    Write-LogLine ('(If you expected a change, check that the profile maps your CPU family "{0}" to a non-None strategy.)' -f $family)
    exit 0
}

$lps = ConvertFrom-AffinityMask -Mask $mask
Write-LogLine ("Affinity mask: 0x{0:X}  LPs=[{1}]  ({2} logical processors)" -f $mask, ($lps -join ','), $lps.Count) 'OK'

# 6. Reference-mask sanity check (optional but cheap)
$ref = Get-ReferenceMaskForCpu -CpuName $topo.CpuName
if ($ref -and $strategyName -like 'BDO*' -or $profile.Id -eq 'BDO') {
    if ($mask -eq $ref.Mask) {
        Write-LogLine ("Reference match: computed mask equals {0} recommendation (0x{1:X})." -f $ref.Source, $ref.Mask) 'OK'
    } elseif ($ref) {
        Write-LogLine ("Reference note: {0} recommends 0x{1:X} for this CPU; we computed 0x{2:X}. This is expected if the guide's recipe differs from the profile's strategy." -f `
            $ref.Source, $ref.Mask, $mask) 'DEBUG'
    }
}

if ($ShowTopology -and -not $LaunchGame -and -not $DryRun) {
    Write-LogLine 'Topology-only mode. Exiting without touching processes.'
    exit 0
}

# Admin check: only enforced once we're past pure read-only modes.
# Launcher-inherit and attach modes both modify processes, so require elevation here.
if (-not $DryRun) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-LogLine 'Administrator privileges are required to apply affinity to protected game processes.' 'ERROR'
        Write-LogLine 'Re-run this script from an elevated PowerShell, or right-click the batch launcher and "Run as administrator".' 'ERROR'
        exit 4
    }
}

# 7. Launcher-inherit mode, if requested
if ($LaunchGame) {
    if (-not (Test-Path $LaunchGame)) {
        Write-LogLine ("Launcher not found: {0}" -f $LaunchGame) 'ERROR'
        exit 3
    }
    $launcherArgs = if ($Steam) { '-steam' } else { '' }
    $maskHex = '{0:X}' -f $mask
    # cmd.exe start /affinity applies the mask to the new process tree.
    # Child processes (including BlackDesert64.exe launched by the launcher)
    # inherit the parent's affinity, which is the canonical approach for
    # anti-cheat-protected games per community practice.
    $cmdLine = 'start "" /affinity {0} /D "{1}" "{2}" {3}' -f $maskHex,
               ([System.IO.Path]::GetDirectoryName($LaunchGame)),
               $LaunchGame, $launcherArgs
    Write-LogLine ("Launcher-inherit mode: cmd.exe /c {0}" -f $cmdLine) 'INFO'
    if ($DryRun) {
        Write-LogLine 'DRY RUN: not launching.' 'DEBUG'
    } else {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmdLine" -WindowStyle Hidden
        Write-LogLine 'Launcher started. The game process will inherit the affinity mask.' 'OK'
        Write-LogLine 'Running watchdog to re-apply priority and catch any child process EAC spawns...'
    }
}

# 8. Attach mode + watchdog
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
Write-LogLine ("Waiting for '{0}.exe' to appear (timeout {1}s)..." -f $effectiveProcessName, $TimeoutSeconds)

$found = $null
while (-not $found -and (Get-Date) -lt $deadline) {
    $found = Get-Process -Name $effectiveProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { Start-Sleep -Milliseconds 500 }
}
if (-not $found) {
    Write-LogLine ("Process '{0}.exe' did not appear within {1}s. Exiting." -f $effectiveProcessName, $TimeoutSeconds) 'WARN'
    exit 0
}

Write-LogLine ("Found {0}.exe (PID {1})" -f $effectiveProcessName, $found.Id) 'OK'

# Apply once to every matching instance
Get-Process -Name $effectiveProcessName -ErrorAction SilentlyContinue | ForEach-Object {
    Set-ProcessAffinityAndPriority -ProcessId $_.Id -Mask $mask -PriorityClass $Priority | Out-Null
}

if ($DryRun) {
    Write-LogLine 'DRY RUN complete. Exiting without entering the watchdog loop (watchdog is a no-op in dry-run mode).' 'DEBUG'
    exit 0
}

# Watchdog until ALL matching processes exit (or Ctrl+C).
# Not a fixed-duration loop - we keep reapplying as long as the game is running,
# in case anti-cheat resets the mask or child processes spawn with a different one.
Write-LogLine 'Watchdog active. Running until game exits (Ctrl+C to stop early).'
$knownState = @{}

while ($true) {
    Start-Sleep -Milliseconds $PollMs
    $procs = @(Get-Process -Name $effectiveProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-LogLine 'Game process(es) exited. Watchdog stopping.' 'OK'
        break
    }

    foreach ($p in $procs) {
        try {
            $current = [uint64]$p.ProcessorAffinity
            if (-not $knownState.ContainsKey($p.Id) -or $current -ne $mask) {
                if ($knownState.ContainsKey($p.Id)) {
                    Write-LogLine ("Affinity drifted on PID {0} (was 0x{1:X}, expected 0x{2:X}). Reapplying." -f $p.Id, $current, $mask) 'WARN'
                } else {
                    Write-LogLine ("New instance detected (PID {0}). Applying affinity." -f $p.Id)
                }
                Set-ProcessAffinityAndPriority -ProcessId $p.Id -Mask $mask -PriorityClass $Priority | Out-Null
            }
            $knownState[$p.Id] = $mask
        } catch {
            # Process likely exited between enumeration and read. Drop it from state.
            $knownState.Remove($p.Id) | Out-Null
        }
    }

    # Prune entries for PIDs that no longer exist
    $livePids = $procs | ForEach-Object { $_.Id }
    @($knownState.Keys) | Where-Object { $_ -notin $livePids } | ForEach-Object {
        $knownState.Remove($_) | Out-Null
    }
}

Write-LogLine '=== Set-GameAffinity exited ==='
