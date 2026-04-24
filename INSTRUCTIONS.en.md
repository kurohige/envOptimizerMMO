# envOptimizerMMO — Usage guide (English)

> Other languages: [Español](INSTRUCTIONS.es.md) · [Reference docs →](README.md)

This guide walks you through using the toolkit step by step. It is the friendlier companion to `README.md`, which is the full technical reference.

---

## What this toolkit does, in plain words

- **`Set-GameAffinity.ps1`** — tells Windows to run your game on a specific set of CPU cores. For BDO on an Intel 13900K this means the 6 fast P-cores (with no hyperthreading and avoiding core 0), which reduces stutter and improves 1% low frame rates. On AMD X3D chips (7950X3D, 9950X3D) it pins the game to the die with the extra L3 cache, where BDO runs best.
- **`GamingMode.ps1`** — a pre-session tool that bumps your power plan to High Performance, frees memory from background apps, flushes DNS, and runs a quick ping test so you know whether your connection is healthy. Everything it changes is reverted when you run it with `-Stop` afterwards.
- **`NetworkOptimize.ps1`** — one-time network tweaks targeted at reducing random disconnects and small-packet latency. Default settings are safe; the riskier tweaks are opt-in behind flags.
- **`Undo-NetworkChanges.ps1`** — rolls back exactly what `NetworkOptimize.ps1` did.
- **`WinMaintenance.ps1`** — weekly housekeeping: clears temp files older than 3 days, Windows Update cache, runs drive optimization (TRIM on SSDs, defrag on HDDs), and a monthly System File Checker. Nothing here is destructive; you can also run it with `-DryRun` to see what would be cleaned.
- **`Setup-Scheduler.ps1`** — registers the maintenance script to run automatically every week.

The two helper files `_CpuTopology.ps1` and `_GameProfile.ps1` are used internally. You don't run them directly.

---

## Before your first run

### Requirements

- Windows 10 (build 1607 or later) or Windows 11.
- PowerShell 5.1 — this ships with Windows, so there is nothing to install.
- Administrator access on the PC (not every script needs admin, but most do).

### Downloading the repository

1. Click the green **Code** button on GitHub → **Download ZIP**.
2. Unzip it anywhere you like. A common place is `D:\envOptimizerMMO\` or `C:\envOptimizerMMO\`.
3. Remember the full path. You'll need it.

### Allowing PowerShell scripts to run

Windows blocks PowerShell scripts by default. The provided `Run-*.bat` launchers work around this automatically using `-ExecutionPolicy Bypass`. If you want to run the `.ps1` files directly from PowerShell, either keep using the batch launchers, or run this **once per user**:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

This allows local scripts to run while still blocking unsigned scripts downloaded from the internet — a safe middle ground.

### Opening PowerShell as administrator

Several of the scripts need administrator rights.

- Press **Windows key** → type **PowerShell** → right-click **Windows PowerShell** → **Run as administrator**.
- In the terminal, navigate to the folder:

```powershell
cd "D:\envOptimizerMMO"
```

Alternatively, the batch launchers handle elevation for you: right-click any `Run-*.bat` file and choose **Run as administrator**.

---

## Quick start (5 minutes)

This is the shortest path from zero to "my game runs better."

```powershell
# 1. Look at your CPU (no admin needed — nothing is changed)
.\Set-GameAffinity.ps1 -ShowTopology

# 2. Apply safe network tweaks (admin required). Reboot afterwards.
.\NetworkOptimize.ps1

# 3. Register weekly maintenance (admin required). One time only.
.\Setup-Scheduler.ps1
```

Now, every time you game:

```powershell
# Before starting the game
.\GamingMode.ps1

# Launch BDO with pre-applied affinity (replace the path with your installation)
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"

# After the session — revert GamingMode changes
.\GamingMode.ps1 -Stop
```

That's it. Skip ahead to the per-script details below only if something doesn't work, or if you want to customize.

---

## First-time setup, in detail

### Step 1: See what the tool detects on your CPU

```powershell
.\Set-GameAffinity.ps1 -ShowTopology
```

You'll see a table of your physical cores, which are P-cores and E-cores (if Intel hybrid), how many logical processors each core has, and your L3 cache grouping. If you're on AMD X3D, you should see two CCDs with different L3 sizes, and one flagged as **V-CACHE CCD**.

At the bottom it will print the BDO affinity mask it would compute for your chip, for example `0x1554` on an i9-13900K. **This step changes nothing** — it just tells you what the tool sees.

### Step 2: Apply the network optimization once

```powershell
.\NetworkOptimize.ps1
```

This creates a full registry backup in the `backups\` folder before making any change, so you can always revert. Recommended **reboot after**.

What runs by default:
- Disables NIC power management (common cause of random Wi-Fi/Ethernet drops).
- Disables Energy Efficient Ethernet on wired adapters.
- Sets the MMCSS registry so your games get CPU priority over background work.

What you can opt in to:
- `-AggressiveTcp` — per-interface Nagle/ACK-delay disables. Helps some games, not clearly proven for BDO.
- `-AggressiveKeepalive` — 60-second TCP keepalive system-wide. Note this affects every network connection on your PC, not just the game.
- `-SetDNS cloudflare` or `-SetDNS google` — changes DNS. Only meaningful if your ISP's DNS is slow or unreliable.

If something feels off after this step, run `.\Undo-NetworkChanges.ps1` and reboot.

### Step 3: Schedule weekly maintenance

```powershell
.\Setup-Scheduler.ps1
```

By default this creates a scheduled task that runs `WinMaintenance.ps1` every Sunday at 3:00 AM. If your PC is off at that time, it runs next time you turn it on. You can change the day/time:

```powershell
.\Setup-Scheduler.ps1 -Day Saturday -Time "04:00"
```

To remove the scheduled task:

```powershell
.\Setup-Scheduler.ps1 -Remove
```

---

## Using the tools, session by session

### Before you play

```powershell
.\GamingMode.ps1
```

Default behavior (safe):
- Power plan → High Performance (not Ultimate — see note below).
- Trims memory from background apps.
- Reports whether Memory Integrity / VBS is enabled (it costs 3–8% CPU in games; the tool only reports, it does not disable).
- Flushes DNS cache.
- Runs a connection quality test and shows your latency/jitter.
- Lists any heavy background apps still running (OneDrive, Chrome, Discord, etc.) so you can close them if you want.
- Also runs `NetworkOptimize.ps1` with safe defaults.

Useful flags:
- `-Ultimate` — use Ultimate Performance plan. **Refused on laptops** (causes thermal throttling and battery drain). Desktop users: slightly more aggressive than High Performance, but the measurable difference in games is under 1%.
- `-DisableMemoryCompression` — opt-in. Reduces compressor CPU overhead on systems with plenty of RAM. Re-enabled automatically on `-Stop`.
- `-DisablePciLinkPower` — opt-in. Disables PCI Express ASPM. Only apply if you've diagnosed real latency spikes traceable to it. Re-enabled automatically on `-Stop`.
- `-GameMode enable` or `-GameMode disable` — explicit control over Windows Game Mode. Default is to leave the current setting alone.
- `-SkipNetwork` — skip the network optimization step (handy if you already ran it today).

### Launching the game

You have two choices.

**Option A — Launcher-inherit mode (recommended for BDO).** The script launches the BDO launcher with the affinity already applied, so the game inherits the mask before EasyAntiCheat starts watching.

```powershell
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"
```

If you play through Steam:

```powershell
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe" -Steam
```

**Option B — Attach mode.** Start BDO normally, then run the script; it waits for the game process to appear and applies affinity + a watchdog that re-applies if EAC changes the mask.

```powershell
.\Set-GameAffinity.ps1
```

Both modes work. Option A is the community-standard approach and usually more reliable.

### After you're done

```powershell
.\GamingMode.ps1 -Stop
```

This undoes everything `GamingMode.ps1` changed: power plan, memory compression (if you disabled it), PCI link power, Game Mode toggle.

---

## Reverting things

- **Network tweaks**: `.\Undo-NetworkChanges.ps1`. Reboot after.
- **Session tweaks (power plan, memory compression, PCI link power, Game Mode)**: `.\GamingMode.ps1 -Stop`.
- **Scheduled maintenance**: `.\Setup-Scheduler.ps1 -Remove`.
- **CPU affinity**: when the game process exits, affinity is gone. If you want to stop the watchdog while the game is still running, press **Ctrl+C** in the PowerShell window.

---

## Troubleshooting

**"The script cannot be run because it contains a `#requires` statement for running as Administrator."**
The current PowerShell window isn't elevated. Either re-open PowerShell as administrator, or right-click the `Run-*.bat` launcher and choose Run as administrator.

**"BDO's affinity keeps resetting mid-session."**
EasyAntiCheat can reset process affinity. Two solutions:
1. Use `-LaunchGame` mode — EAC sees the mask from the start and generally leaves it alone.
2. The watchdog in attach mode detects drift and re-applies. Check the log for lines like `Affinity drifted on PID ... Reapplying.` — if they appear repeatedly, EAC is fighting us; switch to `-LaunchGame` mode.

**"`Set-GameAffinity.ps1 -ShowTopology` doesn't show my X3D as V-Cache."**
The L3-size detection needs two CCDs with clearly different L3 sizes (≥2× ratio). On 7800X3D / 9800X3D (single CCD) there's no asymmetry to detect — that's expected, and the BDO strategy still applies correctly for single-CCD X3D parts. On 7950X3D / 9950X3D, if only one CCD is shown, update your AMD chipset driver and reboot.

**"I ran something and my PC feels weird."**
Run the matching undo. `.\Undo-NetworkChanges.ps1` for network; `.\GamingMode.ps1 -Stop` for gaming-session tweaks. Reboot after network changes.

**"Game Mode — should I enable or disable it?"**
Default is to leave it alone. On Windows 11 most players leave it enabled. On Windows 10 some reports indicate it starves other background apps (notably OBS streams). Microsoft does not publish an official position on this difference. Pass `-GameMode disable` to GamingMode.ps1 if you're on Windows 10 and streaming; otherwise leave it.

**"Memory Integrity / VBS — should I disable it?"**
The script reports its status and does not change it. Disabling it gives you back 3–8% CPU in games but reduces kernel-driver isolation (the main protection VBS provides). For a pure gaming rig, many people disable it and accept the tradeoff. Toggle at **Settings → Windows Security → Device Security → Core Isolation**. A BIOS reboot is required.

---

## Where to go for deeper information

- `README.md` is the full reference: every tweak with its source, why we apply it or skip it, and a section on GPU driver settings, BDO in-game settings, service disables, and hardware recommendations that we deliberately do not automate.
- The BDO-specific CPU affinity recipe is based on [ACanadianDude's Ultimate BDO Performance Guide](https://docs.google.com/document/d/1cyLaDiPL_B6nOZw_qPE_wOGuoeRT-qddTjevTFoFBkg/edit). Read it if you want the reasoning behind the 6-P-cores/no-HT/skip-core-0 recipe.

If something isn't working or you think a recommendation is wrong, open an issue on the repository.
