#Requires -Version 5.1
<#
    _GameProfile.ps1 — dot-sourced helper.

    Loads games.json and resolves an abstract affinity strategy against a
    live CPU topology into a concrete UInt64 affinity mask.

    Strategies compose from these primitives:
        Include       : 'All' | 'PCoresOnly' | 'VCacheCCD'
        Smt           : 'Keep' | 'Disable'
        ExcludeCore0  : bool
        MaxPhysicalCores : int | 0   (0 means no limit)
        IsolateToCcd  : 'None' | 'First' | 'Second' | 'VCache' | 'Largest'

    Named strategies (shorthand for common combos):
        None, AllCores, AllPCoresKeepHT, AllPCoresNoHT,
        BDO-Aggressive, VCacheCCDOnly-NoSMT, FirstCCDOnly-NoSMT-SixCores

    Exposed functions:
        Get-GameProfile           Look up a profile from games.json by id or process name.
        Resolve-AffinityMask      Apply a strategy (or plan) against a topology -> mask.
        Get-ReferenceMaskForCpu   Look up BDO-guide reference mask for a known SKU.
#>

# ------------------------------------------------------------------
#  games.json loader
# ------------------------------------------------------------------
function Get-GameProfile {
    <#
      Load games.json and return the profile matching -GameId or -ProcessName.
      Falls back to the defaultProfile entry if no match.
    #>
    param(
        [string]$GameId,
        [string]$ProcessName,
        [string]$ProfilePath = (Join-Path $PSScriptRoot 'games.json')
    )

    if (-not (Test-Path $ProfilePath)) {
        throw "games.json not found at: $ProfilePath"
    }

    $json = Get-Content $ProfilePath -Raw | ConvertFrom-Json

    $match = $null
    if ($GameId) {
        $match = $json.profiles | Where-Object { $_.id -eq $GameId } | Select-Object -First 1
    }
    if (-not $match -and $ProcessName) {
        $match = $json.profiles |
            Where-Object { $_.processName -eq $ProcessName -or $_.processName -eq "$ProcessName.exe" } |
            Select-Object -First 1
    }

    if ($match) {
        return [pscustomobject]@{
            Id               = $match.id
            DisplayName      = $match.displayName
            ProcessName      = $match.processName
            AffinityStrategy = $match.affinityStrategy
            PriorityClass    = $match.priorityClass
            Notes            = $match.notes
            IsDefault        = $false
        }
    }

    # Fallback: default profile
    $d = $json.defaultProfile
    return [pscustomobject]@{
        Id               = 'Default'
        DisplayName      = 'Default (unknown game)'
        ProcessName      = $ProcessName
        AffinityStrategy = $d.affinityStrategy
        PriorityClass    = $d.priorityClass
        Notes            = $d.notes
        IsDefault        = $true
    }
}

# ------------------------------------------------------------------
#  Strategy selector — chooses a strategy name for the current topology
# ------------------------------------------------------------------
function Select-StrategyForTopology {
    <#
      Given a profile's affinityStrategy block (which maps topology family -> strategy name)
      and a live topology, return the strategy name to use.

      The affinityStrategy object shape in games.json:
          {
            "intelHybrid":      "BDO-Aggressive",
            "intelClassic":     "SixPCoresNoHTSkipCore0",
            "amdX3DDualCCD":    "VCacheCCDOnly-NoSMT",
            "amdX3DSingleCCD":  "AllCoresNoSMTSkipCore0",
            "amdMultiCCD":      "SecondCCDOnly-NoSMT-SixCores",
            "amdSingleCCD":     "AllCoresNoSMT",
            "fallback":         "None"
          }
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Topology,
        [Parameter(Mandatory)][PSCustomObject]$StrategyMap
    )

    $vendor   = $Topology.Vendor
    $hybrid   = $Topology.IsHybrid
    $ccdCount = @($Topology.Ccds).Count
    $pCoreCnt = @($Topology.PCores).Count
    $hasSmt   = ($Topology.PhysicalCores | Where-Object { $_.HasSmt } | Measure-Object).Count -gt 0

    # Family inference for strategy selection.
    # Note: we distinguish 8+-core from <=6-core AMD single-CCD because the
    # BDO guide recommends excluding core 0 only when we have cores to spare.
    $family = switch ($true) {
        ($vendor -eq 'Intel' -and $hybrid)                { 'intelHybrid';       break }
        ($vendor -eq 'Intel')                              { 'intelClassic';      break }
        ($vendor -eq 'AMD'   -and $Topology.HasX3DVCache) { 'amdX3DDualCCD';     break }
        ($vendor -eq 'AMD'   -and $ccdCount -ge 2)        { 'amdMultiCCD';       break }
        ($vendor -eq 'AMD'   -and $pCoreCnt -ge 8)        { 'amdSingleCCD8Plus'; break }
        ($vendor -eq 'AMD')                                { 'amdSingleCCDSmall'; break }
        default                                            { 'fallback';          break }
    }

    $strategy = $null
    if ($StrategyMap.PSObject.Properties.Name -contains $family) {
        $strategy = $StrategyMap.$family
    }
    if (-not $strategy -and $StrategyMap.PSObject.Properties.Name -contains 'fallback') {
        $strategy = $StrategyMap.fallback
    }
    if (-not $strategy) { $strategy = 'None' }

    return [pscustomobject]@{
        Family      = $family
        Strategy    = $strategy
    }
}

# ------------------------------------------------------------------
#  Strategy -> Plan translator
# ------------------------------------------------------------------
function ConvertTo-AffinityPlan {
    <#
      Translate a named strategy to a plan hashtable.
      Plan fields:
        Include          : 'All' | 'PCoresOnly'
        Smt              : 'Keep' | 'Disable'
        ExcludeCore0     : bool
        MaxPhysicalCores : int   (0 = no limit)
        IsolateToCcd     : 'None' | 'VCache' | 'First' | 'Second' | 'Largest'
    #>
    param([Parameter(Mandatory)][string]$Strategy)

    switch ($Strategy) {
        'None' {
            return @{ Include='All'; Smt='Keep'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='None' }
        }
        'AllCores' {
            return @{ Include='All'; Smt='Keep'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='None' }
        }
        'AllPCoresKeepHT' {
            return @{ Include='PCoresOnly'; Smt='Keep'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='None' }
        }
        'AllPCoresNoHT' {
            return @{ Include='PCoresOnly'; Smt='Disable'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='None' }
        }
        'AllCoresNoSMT' {
            return @{ Include='All'; Smt='Disable'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='None' }
        }
        'AllCoresNoSMTSkipCore0' {
            return @{ Include='All'; Smt='Disable'; ExcludeCore0=$true; MaxPhysicalCores=0; IsolateToCcd='None' }
        }
        'SixPCoresNoHTSkipCore0' {
            # Intel classic (pre-hybrid) 8+ core with HT: BDO guide recipe.
            return @{ Include='PCoresOnly'; Smt='Disable'; ExcludeCore0=$true; MaxPhysicalCores=6; IsolateToCcd='None' }
        }
        'BDO-Aggressive' {
            # Intel hybrid 12th/13th/14th gen: 6 P-cores, no HT, exclude core 0, no E-cores.
            # Matches the user's current 13900K mask 0x1554 exactly.
            return @{ Include='PCoresOnly'; Smt='Disable'; ExcludeCore0=$true; MaxPhysicalCores=6; IsolateToCcd='None' }
        }
        'VCacheCCDOnly-NoSMT' {
            # AMD X3D dual-CCD (7950X3D, 9950X3D, 7900X3D): isolate to V-Cache die, no SMT.
            return @{ Include='All'; Smt='Disable'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='VCache' }
        }
        'FirstCCDOnly-NoSMT' {
            # AMD non-X3D multi-CCD: isolate to one chiplet.
            return @{ Include='All'; Smt='Disable'; ExcludeCore0=$false; MaxPhysicalCores=0; IsolateToCcd='First' }
        }
        'SecondCCDOnly-NoSMT-SixCores' {
            # BDO guide convention for Ryzen 9 3900X/5900X/7900X: second CCD only, 6 cores, no SMT.
            return @{ Include='All'; Smt='Disable'; ExcludeCore0=$false; MaxPhysicalCores=6; IsolateToCcd='Second' }
        }
        default {
            throw "Unknown affinity strategy: '$Strategy'. See _GameProfile.ps1 for the allowed list."
        }
    }
}

# ------------------------------------------------------------------
#  Plan + Topology -> UInt64 mask
# ------------------------------------------------------------------
function Resolve-AffinityMask {
    <#
      Apply an affinity plan to a live CPU topology, producing a UInt64 mask.
      Returns 0 if the plan says "no change" (None strategy); callers should
      interpret 0 as "skip affinity modification."
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Topology,
        [Parameter(Mandatory, ParameterSetName='ByStrategy')][string]$Strategy,
        [Parameter(Mandatory, ParameterSetName='ByPlan')][hashtable]$Plan
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByStrategy') {
        if ($Strategy -eq 'None') { return [uint64]0 }
        $Plan = ConvertTo-AffinityPlan -Strategy $Strategy
    }

    # 1. Seed physical-core set
    $cores = if ($Plan.Include -eq 'PCoresOnly') { @($Topology.PCores) }
             else                                { @($Topology.PhysicalCores) }

    # 2. CCD isolation
    $ccdMask = $null
    switch ($Plan.IsolateToCcd) {
        'None'    { }
        'VCache'  {
            if ($Topology.HasX3DVCache) { $ccdMask = [uint64]$Topology.VCacheCcdMask }
            else {
                Write-Warning 'Strategy requests V-Cache CCD isolation, but no V-Cache CCD was detected. Skipping CCD filter.'
            }
        }
        'First'   {
            if ($Topology.Ccds.Count -ge 1) { $ccdMask = [uint64]$Topology.Ccds[0].LogicalProcessorMask }
        }
        'Second'  {
            if ($Topology.Ccds.Count -ge 2) { $ccdMask = [uint64]$Topology.Ccds[1].LogicalProcessorMask }
            elseif ($Topology.Ccds.Count -eq 1) {
                Write-Warning 'Strategy requests second CCD isolation, but only one CCD was detected. Falling back to the single CCD.'
                $ccdMask = [uint64]$Topology.Ccds[0].LogicalProcessorMask
            }
        }
        'Largest' {
            if ($Topology.Ccds.Count -ge 1) {
                $largest = $Topology.Ccds | Sort-Object L3SizeBytes -Descending | Select-Object -First 1
                $ccdMask = [uint64]$largest.LogicalProcessorMask
            }
        }
    }

    if ($null -ne $ccdMask) {
        $cores = @($cores | Where-Object {
            ([uint64]$_.LogicalProcessorMask -band $ccdMask) -ne 0
        })
    }

    # 3. Drop core 0 if requested
    if ($Plan.ExcludeCore0 -and $cores.Count -gt 0) {
        # Physical core that owns logical processor 0
        $core0Owner = $cores | Where-Object {
            ([uint64]$_.LogicalProcessorMask -band [uint64]1) -ne 0
        } | Select-Object -First 1
        if ($core0Owner) {
            $cores = @($cores | Where-Object { $_.Index -ne $core0Owner.Index })
        }
    }

    # 4. Cap physical-core count
    if ($Plan.MaxPhysicalCores -gt 0 -and $cores.Count -gt $Plan.MaxPhysicalCores) {
        $cores = @($cores | Select-Object -First $Plan.MaxPhysicalCores)
    }

    # 5. SMT decision: Keep => all LPs from each core;  Disable => first LP only.
    $lps = @()
    foreach ($c in $cores) {
        if ($Plan.Smt -eq 'Disable') {
            if ($c.LogicalProcessors.Count -gt 0) {
                $lps += ($c.LogicalProcessors | Sort-Object)[0]
            }
        } else {
            $lps += $c.LogicalProcessors
        }
    }
    $lps = @($lps | Sort-Object -Unique)

    if ($lps.Count -eq 0) {
        Write-Warning 'Resolved affinity plan yields zero logical processors. Falling back to no-change (mask 0).'
        return [uint64]0
    }

    return (ConvertTo-AffinityMask -LogicalProcessors $lps)
}

# ------------------------------------------------------------------
#  Reference mask lookup — validates our computation against ACanadianDude's guide
# ------------------------------------------------------------------
function Get-ReferenceMaskForCpu {
    <#
      Returns the BDO-guide's known-good mask for a recognized SKU name, or $null.
      Used during -ShowTopology / -DryRun to sanity-check our computed mask
      against a reputable external reference. We NEVER blindly use these values
      in place of topology-derived computation; they're only for verification.

      Source: ACanadianDude's Ultimate BDO Performance Guide.
    #>
    param([Parameter(Mandatory)][string]$CpuName)

    $table = @(
        # Ryzen 3/5 Zen/Zen+ entries omitted: guide says "probably don't tweak".
        @{ Pattern = '(?i)Ryzen\s+5\s+1600|Ryzen\s+5\s+2600'; Mask = [uint64]0x540  }   # 2CCX x3c: LPs 6,8,10
        @{ Pattern = '(?i)Ryzen\s+7\s+(1700|1800|2700)';      Mask = [uint64]0x5500 }   # 2CCX x4c: LPs 8,10,12,14
        @{ Pattern = '(?i)Ryzen\s+5\s+(3600|5600|7600)';      Mask = [uint64]0x555  }   # LPs 0,2,4,6,8,10
        @{ Pattern = '(?i)Ryzen\s+7\s+(3700|3800)';           Mask = [uint64]0x5550 }   # LPs 4,6,8,10,12,14
        @{ Pattern = '(?i)Ryzen\s+7\s+(5800X|5800X3D|7800X|7800X3D)'; Mask = [uint64]0x5554 } # LPs 2,4,6,8,10,12,14
        @{ Pattern = '(?i)Ryzen\s+9\s+(3900|5900|7900)(?!X3D)';       Mask = [uint64]0x555000 } # LPs 12,14,16,18,20,22 (second CCD)
        @{ Pattern = '(?i)Ryzen\s+9\s+7900X3D';               Mask = [uint64]0x555  }   # LPs 0,2,4,6,8,10 (V-Cache CCD)
        @{ Pattern = '(?i)Ryzen\s+9\s+(3950|5950|7950)(?!X3D)';       Mask = [uint64]0x5550000 } # second CCD 6 cores
        @{ Pattern = '(?i)Ryzen\s+9\s+7950X3D';               Mask = [uint64]0x5555 }   # LPs 0,2,4,6,8,10,12,14 (V-Cache CCD)
        # Intel (BDO guide's generic recipe for 8+ core Intel with HT)
        @{ Pattern = '(?i)Core.*i7-9700K';                    Mask = [uint64]0xFC   }   # LPs 2..7 (no HT to exclude)
        @{ Pattern = '(?i)Core.*i9-13900K?';                  Mask = [uint64]0x1554 }   # user's rig: LPs 2,4,6,8,10,12
    )

    foreach ($entry in $table) {
        if ($CpuName -match $entry.Pattern) {
            return [pscustomobject]@{
                Mask   = $entry.Mask
                Source = "ACanadianDude's BDO Guide"
            }
        }
    }
    return $null
}
