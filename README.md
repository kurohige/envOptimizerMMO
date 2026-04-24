# envOptimizerMMO

PowerShell toolkit for safely optimizing a Windows 10 / Windows 11 PC for MMO gaming. Ships with a first-class profile for Black Desert Online and a generic framework any game can plug into.

**Designed around a principle:** the best optimization for gaming is not the most aggressive one. Scripts apply only tweaks with real evidence of benefit; anything folklore-heavy, vendor-specific, or with meaningful downside is either opt-in behind a flag or documented here as a manual recommendation.

**Built for:** Windows 10 (1607+) and Windows 11. PowerShell 5.1 (ships with Windows — no install needed). Intel hybrid (12th/13th/14th gen + Core Ultra), Intel classic, AMD Ryzen including X3D cache-aware pinning. Ethernet and Wi-Fi (with battery-aware handling for laptops).

---

## Contents

- [Quick start](#quick-start)
- [Script reference](#script-reference)
- [Game profiles](#game-profiles)
- [Why these tweaks? (with sources)](#why-these-tweaks-with-sources)
- [Further optimizations not automated](#further-optimizations-not-automated)
  - [GPU driver settings](#gpu-driver-settings-readme-only)
  - [In-game BDO settings](#in-game-bdo-settings)
  - [Service / service-like tweaks](#service--service-like-tweaks)
  - [Memory and storage](#memory-and-storage)
- [Windows 10 vs Windows 11](#windows-10-vs-windows-11)
- [Troubleshooting](#troubleshooting)
- [What this toolkit does NOT do](#what-this-toolkit-does-not-do)
- [Credits and sources](#credits-and-sources)

---

## Quick start

```powershell
# Open an elevated PowerShell in this folder
cd D:\path\to\envOptimizerMMO

# One-time: see what the tool detects on your CPU (no admin needed, no changes)
.\Set-GameAffinity.ps1 -ShowTopology

# One-time: network optimization (safe defaults; reboot recommended)
.\NetworkOptimize.ps1

# One-time: schedule weekly maintenance
.\Setup-Scheduler.ps1

# Each gaming session - before launching the game:
.\GamingMode.ps1

# And, for BDO specifically, set CPU affinity:
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"

# After the session:
.\GamingMode.ps1 -Stop
```

Or with double-click launchers (right-click → Run as administrator):

- `Run-Maintenance.bat`
- `Run-GamingMode.bat`
- `Run-GameAffinity.bat`

---

## Script reference

| Script | Purpose |
|---|---|
| `Set-GameAffinity.ps1` | Sets CPU affinity per game profile. Topology-aware: detects P/E cores on Intel hybrid, CCDs and V-Cache die on AMD. |
| `GamingMode.ps1` | Pre-session optimizer: power plan, memory trim, connection test, VBS status report. Reversible with `-Stop`. |
| `NetworkOptimize.ps1` | One-time network tweaks. Safe defaults + opt-in aggressive flags. |
| `Undo-NetworkChanges.ps1` | Reverts exactly what NetworkOptimize applied (reads undo info from backups\). |
| `WinMaintenance.ps1` | Weekly cleanup: temp files, Windows Update cache, DISM, SFC (monthly), drive optimization. |
| `Setup-Scheduler.ps1` | Registers the weekly maintenance task in Task Scheduler. |
| `_CpuTopology.ps1` | Helper (dot-sourced): CPU topology detection via `GetLogicalProcessorInformationEx`. |
| `_GameProfile.ps1` | Helper (dot-sourced): resolves profile + topology → concrete affinity mask. |
| `games.json` | Game profile registry. Ships with BDO; anyone can add more. |

### `Set-GameAffinity.ps1` modes

**Attach mode (default):** waits for the game process to start, then applies affinity + priority. A watchdog reapplies if the game spawns child processes or anti-cheat resets the mask. Runs until the game exits.

**Launcher-inherit mode (`-LaunchGame <path>`):** starts the game launcher with the affinity mask pre-applied via `cmd /c start /affinity`. The game process inherits the mask before EasyAntiCheat (EAC) attaches. This is the canonical BDO community approach and is more reliable when EAC is present.

```powershell
# See your CPU and the computed BDO mask. No admin required.
.\Set-GameAffinity.ps1 -ShowTopology

# Attach to BlackDesert64 when it appears
.\Set-GameAffinity.ps1

# Recommended: launcher-inherit for BDO (EAC-compatible)
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"

# Steam-managed BDO
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe" -Steam

# Try a different profile or an ad-hoc process
.\Set-GameAffinity.ps1 -GameId BDO -DryRun
.\Set-GameAffinity.ps1 -ProcessName MyGame64 -Strategy AllPCoresKeepHT
```

---

## Game profiles

Game profiles are defined in `games.json`. Each profile maps **topology families** to **named affinity strategies**. The resolver detects your live CPU topology at runtime, picks the appropriate family, applies the strategy, and computes the mask from the topology — no hardcoded hex.

Topology families the resolver understands:

| Family | Matches |
|---|---|
| `intelHybrid` | Intel 12/13/14th gen, Core Ultra (any CPU reporting multiple `EfficiencyClass` values) |
| `intelClassic` | Intel non-hybrid (≤11th gen) |
| `amdX3DDualCCD` | AMD X3D dual-CCD parts (7900X3D, 7950X3D, 9950X3D) — detected by L3 size asymmetry |
| `amdMultiCCD` | AMD non-X3D dual-CCD (3900X, 5900X, 5950X, 7900X, 7950X, 9950X) |
| `amdSingleCCD8Plus` | AMD single-CCD, 8+ cores (5800X, 7700X, 7800X3D, 9800X3D) |
| `amdSingleCCDSmall` | AMD single-CCD, ≤6 cores (5600X, 7600X) |
| `fallback` | Anything else — always safe to apply `None` here |

Strategies:

| Strategy | What it does |
|---|---|
| `None` | No affinity change. Safest. |
| `AllCores` | Every core, SMT on. |
| `AllPCoresKeepHT` | P-cores only on hybrid Intel; keep HT. All cores on non-hybrid. |
| `AllPCoresNoHT` | P-cores only, one LP per core (disable HT in software). |
| `AllCoresNoSMT` | All cores, one LP each. |
| `AllCoresNoSMTSkipCore0` | All cores except the one owning LP 0, SMT off. |
| `SixPCoresNoHTSkipCore0` | Up to 6 P-cores, skip core 0, no HT. Intel classic BDO recipe. |
| `BDO-Aggressive` | 6 P-cores, no HT, skip core 0, no E-cores. Matches the i9-13900K `0x1554` recipe exactly. |
| `VCacheCCDOnly-NoSMT` | AMD X3D dual-CCD: pin to the V-Cache die, SMT off. |
| `FirstCCDOnly-NoSMT` | Isolate to first CCD on multi-CCD AMD (non-X3D). |
| `SecondCCDOnly-NoSMT-SixCores` | Second CCD only, ≤6 cores, SMT off. The BDO guide's Ryzen 9 non-X3D recipe. |

### Adding a game

1. Open `games.json`.
2. Copy the BDO block and change `id`, `displayName`, `processName`, and the `affinityStrategy` per-family mappings.
3. Save.
4. Run `.\Set-GameAffinity.ps1 -GameId <yourId> -DryRun -ShowTopology` to confirm.

If a game doesn't benefit from affinity tuning (most don't), the safest profile is one that maps every family to `None`.

---

## Why these tweaks? (with sources)

Each script's defaults were chosen against Microsoft's own documentation wherever possible. Folklore-heavy or context-dependent tweaks are opt-in behind flags; some things you'll find on other gaming-tweak sites aren't here at all because they are actively wrong on modern Windows.

### CPU affinity

- **Hybrid CPU detection** uses `GetLogicalProcessorInformationEx` (Win32) to read the `EfficiencyClass` field of each physical core. This is the documented way to distinguish P-cores from E-cores and is forward-compatible with future hybrids that may have 3+ classes. Source: [MSDN — PROCESSOR_RELATIONSHIP structure](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-processor_relationship).
- **AMD X3D V-Cache detection** is inferred from L3-cache-size asymmetry between CCDs (ratio ≥ 2.0×). There is no documented Windows API that flags the V-Cache die; per-CCD L3 size is the only topology-based signal. Validated against public specifications for Ryzen 7000X3D / 9000X3D parts.
- **BDO affinity recipe** — 6 P-cores, no HT, skip core 0, no E-cores — is drawn from [ACanadianDude's Ultimate BDO Performance Guide](https://docs.google.com/document/d/1cyLaDiPL_B6nOZw_qPE_wOGuoeRT-qddTjevTFoFBkg/edit) and extensive community testing. The underlying rationale:
  - **BDO does not benefit from SMT/HT.** Worker threads thrash shared core resources.
  - **E-cores are slow and cache-poor.** Any thread that lands on one stalls.
  - **Capping at 6 physical cores** limits scheduler migration overhead; BDO rarely spawns more than ~8 hot threads.
  - **Skipping core 0** leaves Windows' preferred scheduling core for background threads, reducing contention.
- **Classic `SetProcessAffinityMask`** (Win32) is used rather than the newer CPU Sets API. Hard affinity is consistent with `cmd /c start /affinity` semantics (EAC-compatible launcher inheritance) and is available on every supported Windows version. The CPU Sets "soft affinity" variant (`SetProcessDefaultCpuSetMasks`) requires Windows 11 build 22000+ and offers only a preference, not a guarantee. Source: [MSDN — SetProcessAffinityMask](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask), [MSDN — CPU Sets](https://learn.microsoft.com/en-us/windows/win32/procthread/cpu-sets).

### Network

**Applied by default** (real evidence of benefit, low/no downside):

- **Disable NIC power management.** [MSDN — NIC tuning for low latency](https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics) recommends disabling PnP power saving for latency-sensitive packet processing. The script keeps this on for Wi-Fi + battery combinations to preserve battery life.
- **Disable Energy Efficient Ethernet (EEE / 802.3az)** on Ethernet only. LPI (Low Power Idle) wake-negotiation adds ~10–50 ms spikes on some adapters (notably Realtek RTL8125). On Intel I225/I226 it's usually a no-op. Skipped on Wi-Fi (EEE doesn't apply).
- **`NetworkThrottlingIndex = 0xFFFFFFFF`.** Disables MMCSS's network-packet throttle. Caveat: this is a community-sourced recommendation. Microsoft's current [MMCSS page](https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service) no longer documents this key; the reference is legacy KB 948066.
- **`SystemResponsiveness = 10`.** Reserves 10% of CPU for low-priority tasks; gives MMCSS 90% for multimedia work (games). Microsoft [MMCSS docs](https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service) explicitly state that values below 10 are clamped to 20, and a value of 100 disables MMCSS entirely — so `10` is the documented floor. The old script's `0` silently became `20` (a no-op); this fixes that.

**Opt-in via flags** (benefit is debated or has real side effects):

- **`-AggressiveTcp`** — sets `TcpNoDelay=1` and `TcpAckFrequency=1` on the game-bound interface. These disable Nagle's algorithm and delayed-ACK. The tweak originated in CS-era small-packet-per-frame games. BDO uses larger batched packets; benefit is not well-evidenced. Left opt-in because no current Microsoft document endorses these registry keys for gaming. Reverted by `Undo-NetworkChanges.ps1`.
- **`-AggressiveKeepalive`** — sets 60s keepalive system-wide (`KeepAliveTime=60000`, `KeepAliveInterval=1000`). Affects **every** TCP connection on the box — browsers, RDP, email. Most games have application-level keepalives and don't need this. BDO does not measurably benefit.
- **`-SetDNS cloudflare|google`** — changes DNS. Only affects first-lookup time, not gameplay ping. Useful if your ISP DNS redirects NXDOMAIN or is slow. Default: `skip`.

**Removed from previous versions** (documented no-ops on modern Windows):

- `netsh int tcp set global autotuninglevel=normal` — `normal` is the default.
- Disabling ECN explicitly — already disabled by default on the Internet template.
- Disabling TCP timestamps explicitly — already disabled by default.

### Power plans

- **Default: High Performance.** Empirical testing (HUB, Gamer's Nexus, 2023–24) shows the delta between High Performance and Ultimate Performance in games is <1%. The delta between Balanced and High Performance is 1–5% for single-thread-boost-sensitive games.
- **`-Ultimate` is opt-in** and **refused on battery-powered systems.** Ultimate disables processor idle states, which on laptops causes thermal throttling and shortens battery life dramatically. Microsoft's power-scheme docs don't formally list the Ultimate GUID, but it's ubiquitous across Windows 10 April 2018 Update onward; the script duplicates the scheme if not already present.
- **PCI Express Link State Power Management (`-DisablePciLinkPower`)** is opt-in. Microsoft Learn explicitly warns: *"System administrators should not change the power plan personality settings."* ([source](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/pci-express-settings-link-state-power-management)) Only apply if you have diagnosed latency spikes traceable to PCIe ASPM. Reverted on `-Stop`.

### Memory

- **Working-set trim** is applied by default — calls `EmptyWorkingSet` on non-critical background processes to free pages Windows can reclaim. Non-destructive; OS refills pages on demand.
- **`-DisableMemoryCompression`** is opt-in. Microsoft's [Disable-MMAgent](https://learn.microsoft.com/en-us/powershell/module/mmagent/disable-mmagent) cmdlet is documented, but Microsoft publishes **no RAM-capacity threshold** for the recommendation. Community wisdom says "only on 16+ GB"; the script surfaces this as opt-in with a clear tooltip rather than blocking on a hardcoded threshold. Reverted on `-Stop` with `Enable-MMAgent -MemoryCompression`.

### VBS / HVCI (reported, not changed)

The script reports whether Virtualization-Based Security and Memory Integrity are running — both carry a documented 3–8% CPU cost in games. It **does not toggle them.** This is a security tradeoff the user must make in Windows Settings (`Settings → Windows Security → Device Security → Core Isolation`).

### Tweaks we deliberately don't do

- **Disabling Windows services** (SysMain / Superfetch, Xbox Game Bar, Connected Devices Platform, Windows Search). See the [Service tweaks](#service--service-like-tweaks) section below for why these are README-only.
- **Flipping HAGS (Hardware-Accelerated GPU Scheduling) from the script.** Community evidence is mixed for BDO; current NVIDIA guidance (40/50-series + Frame Generation) is HAGS-on. See the README section on GPU settings.
- **Writing to `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`.** The registry schema used by the Win11 22H2 "Optimizations for windowed games" toggle is undocumented by Microsoft and format can change. Users who want this should toggle it in Settings manually.
- **Per-Game NVIDIA/AMD Control Panel settings.** Registry paths vary by driver version and are not stable.

---

## Further optimizations not automated

These are recommendations — not applied by the scripts — because they're vendor-specific, UI-specific, or carry real risk if applied wrong.

### GPU driver settings (README only)

Applied per the [ACanadianDude BDO guide](https://docs.google.com/document/d/1cyLaDiPL_B6nOZw_qPE_wOGuoeRT-qddTjevTFoFBkg/edit) and current vendor defaults.

#### NVIDIA Control Panel — set these for the BlackDesert profile

| Setting | Value | Why |
|---|---|---|
| Vertical sync | **Off** | You want variable frame rate. Use G-Sync globally if available. |
| Low Latency Mode | **Ultra** (if CPU has headroom) or **On** | Reduces queued frames → less input lag. |
| Power Management Mode | **Prefer Maximum Performance** (30-series+) or **Adaptive** | Prevents GPU downclocking during UI/inventory moments. |
| Threaded Optimizations | **On** (default Auto is fine on 6+ core CPUs) | Helps modern multithreaded rendering. |
| Shader Cache Size | **10 GB or Unlimited** | BDO has a lot of shaders; default is too small. |
| Ansel | **Disabled** | Small stutter reduction. |
| Anti-aliasing Transparency / FXAA | Off in driver (use in-game FXAA if wanted) | Avoid double AA. |

For Windows 11 22H2+ windowed gameplay: enable **Optimizations for windowed games** in `Settings → System → Display → Graphics → Change default graphics settings`. This auto-upgrades windowed presentation to flip-model, letting V-Sync be disabled in windowed mode.

#### AMD Radeon Settings — for the BlackDesert64 profile

| Setting | Value | Why |
|---|---|---|
| Radeon Enhanced Sync | **Enabled** | Equivalent to NVIDIA Fast Sync. |
| Wait for Vertical Refresh | **Off** | Don't let the driver force V-Sync. |
| Radeon Anti-Lag | **Enabled** | Input latency reduction. |
| Radeon Chill | **Off for BDO** | Chill's dynamic FPS cap hurts action games. |
| Texture Filtering Quality | **Performance** | Minor visual tradeoff for small perf gain. |
| Surface Format Optimization | **Enabled** | Default; no reason to disable. |

### In-game BDO settings

Summarized from ACanadianDude's guide. Apply in-game under Settings → Display / UI.

- **Disable low power mode** (background frame-sleep costs real FPS).
- **Effect Optimization** slider ~40% from the left + **Remove Faraway Effects** = critical for sieges / boss raids.
- **TAA** causes blur and input lag; prefer FXAA.
- **Performance Optimization** (keeps assets in RAM) works well on 16+ GB systems.
- **3D minimap** is lighter than the 2D minimap.
- **Attack Decisions** can be disabled if you know BDO combat.
- **World-boss hide-other-players**: press **Shift+F5** at Karanda/Vell/Garmoth only. Disable for PvP.

**Disabling the post-processing sharpening filter** (from the guide): open `Documents\Black Desert\GameOption.txt` and set `postFilter = 0`. Also edit each `Documents\Black Desert\UserCache\<N-digit-folder>\gameVariable.xml` to replace `PostFilter 1` with `PostFilter 0`. Be aware that enabling the in-game Display Filter re-applies the setting.

### Service / service-like tweaks

Per-service risk profile — apply at your own discretion.

| Service / Tweak | Recommendation | Why |
|---|---|---|
| SysMain / Superfetch | **Leave enabled** on 16+ GB SSD systems | Low overhead on modern rigs; "disable for gaming" is HDD-era folklore. |
| Xbox Game Bar | **Do not disable on AMD X3D dual-CCD** | It works with the AMD chipset driver to park game threads onto the V-Cache CCD. Disabling can regress perf on 7950X3D / 9950X3D. |
| Windows Search | Optional disable on dedicated gaming rigs | Saves 1–3% idle CPU and disk I/O on boxes that don't need file search. |
| GameDVR (registry) | **Safe to disable** | `HKCU\System\GameConfigStore\GameDVR_Enabled = 0` and `HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR\AllowGameDVR = 0`. Measurable stutter improvement on some Nvidia + DX11 setups. |
| HAGS (Hardware-Accelerated GPU Scheduling) | Leave at Windows default; turn OFF if diagnosing stutter | Mixed evidence for BDO. HAGS-on is required for DLSS Frame Gen (N/A for BDO), recommended on Nvidia 40/50-series. |

### Memory and storage

- **NVMe SSD for BDO** makes more difference than every software tweak combined. Removes asset-streaming stutter during horse travel and zone loads.
- **SATA SSD** is the minimum — HDDs cause loading walls at high speeds. Don't RAID-0 SSDs, no meaningful gain for BDO.
- **Don't cache NVIDIA Shadowplay to the game SSD.** ShadowPlay writes heavily; on a 500 GB SSD that's ~100+ TB/year, enough to reach TBW-based SSD failure.
- **32 GB RAM with dual-channel + dual-rank** is the sweet spot. DDR4-3200 CL16 or better. On DDR5, aim for 6000 CL30 on Ryzen 7000 X3D (sweet spot for infinity-fabric ratios).

### Third-party tools worth installing

- **[Intelligent Standby List Cleaner (ISLC)](https://www.wagnardsoft.com/forums/viewforum.php?f=18)** — automates standby-cache cleanup, prevents the Windows 10 stutter associated with filled standby memory. Install and enable auto-start.
- **[AutoPowerOptionsOK](https://www.softwareok.com/?seite=Freeware/AutoPowerOptionsOK)** — auto-switches power plans on AFK. Useful if you do BDO life-skill AFK.
- **[nvidiaProfileInspector](https://github.com/Orbmu2k/nvidiaProfileInspector)** — exposes NVIDIA settings the Control Panel doesn't, including LOD bias tweaks for the "OSRS blob" look if that's your jam.

---

## Windows 10 vs Windows 11

This toolkit supports both. Key differences:

- **CPU affinity scripts** work identically on Win10 and Win11. The scripts use `SetProcessAffinityMask` (Win XP+).
- **Power plans** are identical. Ultimate Performance GUID is present on both since Win10 1803.
- **Game Mode** registry toggle is in the same place (HKCU\Software\Microsoft\GameBar). Reports of Win10 Game Mode starving background apps (notably OBS) exist in community sources; Microsoft has not published a formal Win10-vs-Win11 behavioral spec. **The toolkit does not flip Game Mode automatically** — pass `-GameMode enable` or `-GameMode disable` to GamingMode.ps1 if you want explicit control.
- **VBS / Memory Integrity** defaults to ON on Win11 22H2+; on Win10 it's usually off unless explicitly enabled. GamingMode.ps1 reports status on both.
- **Win11 22H2+ windowed flip-model** is a Win11-only feature. On Win10 you must run fullscreen to disable V-Sync effectively.
- **DeliveryOptimization cmdlet** (`WinMaintenance.ps1`) is available on Win10 1703+ and all Win11. The script guards with `Get-Command` to skip gracefully on LTSC / IoT SKUs that omit the module.

---

## Troubleshooting

**"`Set-GameAffinity.ps1` cannot be run because it contains a `#requires` statement for running as Administrator."**
Open PowerShell **as Administrator** before running. The batch launchers do this automatically when right-clicked → Run as administrator.

**"My BDO affinity keeps reverting mid-session."**
EasyAntiCheat can reset process affinity. Two solutions:
1. Use `-LaunchGame` mode — launcher-inherit bypasses EAC's post-launch reset by having the game inherit the mask from birth.
2. The attach-mode watchdog detects drift and re-applies automatically; check the log for `Affinity drifted` entries.

**"Script says `VBS: RUNNING`. Should I disable it?"**
Your call. Disabling improves game performance 3–8% but weakens kernel-driver isolation (the main protection VBS provides). If your PC is only used for gaming and you don't run sketchy drivers or third-party anti-cheats that might be flagged, disabling is a reasonable tradeoff. Toggle at `Settings → Windows Security → Device Security → Core Isolation`. A BIOS reboot is required.

**"I ran NetworkOptimize and my PC feels weird."**
`.\Undo-NetworkChanges.ps1` reverts exactly what was applied. It reads `backups\adapter_settings_*.json` to know which tweaks to undo. Reboot after.

**"My 7950X3D is not being detected as X3D."**
Run `.\Set-GameAffinity.ps1 -ShowTopology`. You should see two L3 cache groupings (CCDs) with different sizes (96 MB + 32 MB). If you only see one CCD, the AMD chipset driver isn't exposing per-CCD L3 correctly — update the driver and reboot. If both CCDs show the same L3 size, your BIOS may have a non-standard cache configuration.

**"My ad-hoc game (-ProcessName) got the wrong profile."**
Ad-hoc runs use the `defaultProfile` entry in `games.json`, which is conservative. Add a proper profile entry for your game (see [Game profiles](#game-profiles)) or pass `-Strategy <name>` to override.

---

## What this toolkit does NOT do

- **Does not disable Windows services** from the script. Service disables live in this README as recommendations.
- **Does not modify GPU driver settings.** Registry paths are driver-version-dependent; this is a README recommendation only.
- **Does not edit BDO config files.** `GameOption.txt` / `gameVariable.xml` tweaks are README-only because a bad edit can corrupt your save.
- **Does not install third-party software** (ISLC, AutoPowerOptionsOK, nvidiaProfileInspector). README links only.
- **Does not toggle HAGS, Memory Integrity, VBS, or Fullscreen Optimizations.** These are security / compatibility tradeoffs the user must make explicitly in Windows Settings.
- **Does not disable Core 0 for the whole system.** Only the game process is restricted — other applications and OS threads continue using all cores normally.
- **Does not touch battery settings on laptops** beyond refusing Ultimate Performance and warning where appropriate.

---

## Credits and sources

- **[ACanadianDude's Ultimate BDO Performance Guide](https://docs.google.com/document/d/1cyLaDiPL_B6nOZw_qPE_wOGuoeRT-qddTjevTFoFBkg/edit)** — source of the BDO-specific affinity recipes and in-game setting recommendations. Attribution is preserved throughout the scripts and README.
- **Microsoft Learn** — primary authoritative source for Win32 API semantics, MMCSS, power plan GUIDs, and CPU topology. Specific pages linked inline.
- **The BDO community on Reddit and Discord** — countless field reports informed which tweaks to keep, move to opt-in, or remove.

## License

MIT — see `LICENSE`. Use freely, attribute if you publish derivatives, no warranty.

## Contributing

Issues and PRs welcome. Particularly:
- Game profiles for other MMOs (FFXIV, Lost Ark, WoW, Guild Wars 2) with measurements/evidence for the affinity strategy chosen.
- Corrections to any of the research citations — if Microsoft publishes authoritative guidance that contradicts something in this README, it should be updated.
- Reports of BDO affinity behavior on Intel Core Ultra (Arrow Lake / Lunar Lake), where current community wisdom is still forming.
