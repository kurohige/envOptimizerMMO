#Requires -Version 5.1
<#
    _CpuTopology.ps1 — dot-sourced helper.

    Detects CPU topology via Win32 GetLogicalProcessorInformationEx:
      - Physical cores with their logical-processor (SMT sibling) bitmask.
      - EfficiencyClass per core (0 = E-core, >=1 = P-core on hybrid Intel).
      - L3 cache groupings per CCD (used to identify AMD X3D V-Cache die).

    No CPU-name string matching is used for topology decisions. The API is the
    authoritative source and works across Intel hybrid (12th/13th/14th + Core
    Ultra), Intel classic, AMD Ryzen classic, and AMD X3D dual-CCD parts.

    Exposed functions:
      Get-CpuTopology       Returns a PSCustomObject describing the CPU.
      Show-CpuTopology      Pretty-prints topology for the user.
      ConvertTo-AffinityMask  Array of logical-processor IDs -> UInt64 mask.
      ConvertFrom-AffinityMask  UInt64 mask -> array of logical-processor IDs.
#>

if (-not ([System.Management.Automation.PSTypeName]'EnvOptimizer.CpuTopologyNative').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace EnvOptimizer {

    public class PhysicalCoreInfo {
        public int    Index;
        public ulong  LogicalProcessorMask;
        public List<int> LogicalProcessors = new List<int>();
        public byte   EfficiencyClass;
        public bool   HasSmt;
    }

    public class CacheInfo {
        public byte   Level;
        public uint   CacheSize;
        public ulong  ProcessorMask;
    }

    public class CpuTopologyResult {
        public List<PhysicalCoreInfo> PhysicalCores = new List<PhysicalCoreInfo>();
        public List<CacheInfo>        Caches        = new List<CacheInfo>();
        public int  TotalLogicalProcessors;
        public bool IsHybrid;
    }

    public static class CpuTopologyNative {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetLogicalProcessorInformationEx(
            int  RelationshipType,
            IntPtr Buffer,
            ref uint ReturnedLength);

        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const int RelationAll = unchecked((int)0xffff);
        private const int RelationProcessorCore = 0;
        private const int RelationCache = 2;

        public static CpuTopologyResult Detect() {
            var r = new CpuTopologyResult();

            uint len = 0;
            GetLogicalProcessorInformationEx(RelationAll, IntPtr.Zero, ref len);
            int err = Marshal.GetLastWin32Error();
            if (err != ERROR_INSUFFICIENT_BUFFER || len == 0) {
                throw new InvalidOperationException(
                    "GetLogicalProcessorInformationEx did not return a buffer size. Win32 error: " + err);
            }

            IntPtr buf = Marshal.AllocHGlobal((int)len);
            try {
                if (!GetLogicalProcessorInformationEx(RelationAll, buf, ref len)) {
                    throw new InvalidOperationException(
                        "GetLogicalProcessorInformationEx failed. Win32 error: " + Marshal.GetLastWin32Error());
                }

                int offset = 0;
                byte maxEff = 0;
                byte minEff = 0xff;

                while (offset < (int)len) {
                    int relationship = Marshal.ReadInt32(buf, offset + 0);
                    int size         = Marshal.ReadInt32(buf, offset + 4);

                    if (size <= 0 || offset + size > (int)len) break;

                    if (relationship == RelationProcessorCore) {
                        // PROCESSOR_RELATIONSHIP layout (after the 8-byte record header):
                        //   offset 8  : byte  Flags         (bit 0 = LTP_PC_SMT)
                        //   offset 9  : byte  EfficiencyClass
                        //   offset 10 : byte  Reserved[20]
                        //   offset 30 : word  GroupCount
                        //   offset 32 : GROUP_AFFINITY GroupMask[GroupCount]
                        //     GROUP_AFFINITY = 8B Mask + 2B Group + 6B Reserved
                        byte flags = Marshal.ReadByte(buf, offset + 8);
                        byte eff   = Marshal.ReadByte(buf, offset + 9);
                        ulong mask = unchecked((ulong)Marshal.ReadInt64(buf, offset + 32));

                        var core = new PhysicalCoreInfo {
                            Index                = r.PhysicalCores.Count,
                            LogicalProcessorMask = mask,
                            EfficiencyClass      = eff,
                            HasSmt               = (flags & 0x1) != 0
                        };
                        for (int i = 0; i < 64; i++) {
                            if ((mask & (1UL << i)) != 0) {
                                core.LogicalProcessors.Add(i);
                                if (i + 1 > r.TotalLogicalProcessors) r.TotalLogicalProcessors = i + 1;
                            }
                        }

                        if (eff > maxEff) maxEff = eff;
                        if (eff < minEff) minEff = eff;
                        r.PhysicalCores.Add(core);
                    }
                    else if (relationship == RelationCache) {
                        // CACHE_RELATIONSHIP layout (after the 8-byte record header).
                        // Verified against MS Learn (ns-winnt-cache_relationship):
                        //   offset 8  : byte  Level
                        //   offset 9  : byte  Associativity
                        //   offset 10 : word  LineSize
                        //   offset 12 : dword CacheSize  (bytes)
                        //   offset 16 : dword Type           (PROCESSOR_CACHE_TYPE enum)
                        //   offset 20 : byte  Reserved[18]
                        //   offset 38 : word  GroupCount
                        //   offset 40 : GROUP_AFFINITY (first of an array of GroupCount entries)
                        // GroupMask at offset 40 is stable across the pre-20348 and 20348+ layouts.
                        // We only need the first GroupMask because on every consumer CPU, each
                        // L3 cache is contained within a single processor group.
                        byte  level     = Marshal.ReadByte(buf,  offset + 8);
                        uint  cacheSize = unchecked((uint)Marshal.ReadInt32(buf, offset + 12));
                        ulong procMask  = unchecked((ulong)Marshal.ReadInt64(buf, offset + 40));

                        r.Caches.Add(new CacheInfo {
                            Level         = level,
                            CacheSize     = cacheSize,
                            ProcessorMask = procMask
                        });
                    }

                    offset += size;
                }

                r.IsHybrid = (maxEff > minEff && r.PhysicalCores.Count > 0);
                return r;
            }
            finally {
                Marshal.FreeHGlobal(buf);
            }
        }
    }
}
'@
}

function ConvertTo-AffinityMask {
    <# Array of logical-processor IDs -> UInt64 mask. #>
    param([Parameter(Mandatory)][int[]]$LogicalProcessors)
    [uint64]$mask = 0
    foreach ($lp in $LogicalProcessors) {
        if ($lp -lt 0 -or $lp -ge 64) { continue }
        $mask = $mask -bor ([uint64]1 -shl $lp)
    }
    return $mask
}

function ConvertFrom-AffinityMask {
    <# UInt64 mask -> sorted array of logical-processor IDs. #>
    param([Parameter(Mandatory)][uint64]$Mask)
    $result = @()
    for ($i = 0; $i -lt 64; $i++) {
        if (($Mask -band ([uint64]1 -shl $i)) -ne 0) { $result += $i }
    }
    return $result
}

function Get-CpuTopology {
    <#
      Returns a PSCustomObject with:
        CpuName                 : string (from WMI, informational only)
        Vendor                  : 'Intel' | 'AMD' | 'Other'
        IsHybrid                : bool (any core has EfficiencyClass > 0)
        TotalLogicalProcessors  : int
        PhysicalCores           : list of PhysicalCoreInfo (all of them)
        PCores                  : list of PhysicalCoreInfo (P-cores on hybrid, all cores on non-hybrid)
        ECores                  : list of PhysicalCoreInfo (empty on non-hybrid)
        Ccds                    : list of @{ L3SizeBytes; LogicalProcessorMask; LogicalProcessors }
                                  one entry per distinct L3 cache grouping
        HasX3DVCache            : bool (AMD only: one CCD has ~3x the L3 of the other)
        VCacheCcdMask           : UInt64 mask of the V-Cache CCD (0 if not detected)
    #>
    $native = [EnvOptimizer.CpuTopologyNative]::Detect()

    $cpuName = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty Name)
    if (-not $cpuName) { $cpuName = 'Unknown CPU' }
    $cpuName = $cpuName.Trim()

    $vendor = if     ($cpuName -match '(?i)intel') { 'Intel' }
              elseif ($cpuName -match '(?i)amd|ryzen|epyc|threadripper') { 'AMD' }
              else   { 'Other' }

    # L3 cache groupings -> CCD view
    $ccds = @()
    $l3 = @($native.Caches | Where-Object { $_.Level -eq 3 })
    foreach ($c in $l3) {
        $ccds += [pscustomobject]@{
            L3SizeBytes          = [uint32]$c.CacheSize
            LogicalProcessorMask = [uint64]$c.ProcessorMask
            LogicalProcessors    = ConvertFrom-AffinityMask -Mask ([uint64]$c.ProcessorMask)
        }
    }

    # AMD X3D V-Cache detection. There is no documented Windows API that flags the
    # V-Cache die; per-CCD L3 size (via RelationCache records) is the only topology-
    # based signal. On a 7950X3D / 9950X3D, one CCD reports 96 MB L3 and the other
    # 32 MB L3 (ratio ~3x). We require >=2x to trigger detection, which accommodates
    # real-world X3D parts while avoiding false positives on unusual SoCs that
    # might trim L3 per-CCD for yield reasons.
    $hasX3D = $false
    $vCacheMask = [uint64]0
    if ($vendor -eq 'AMD' -and $ccds.Count -ge 2) {
        $sizes = $ccds | Select-Object -ExpandProperty L3SizeBytes
        $maxL3 = ($sizes | Measure-Object -Maximum).Maximum
        $minL3 = ($sizes | Measure-Object -Minimum).Minimum
        if ($minL3 -gt 0 -and ($maxL3 / $minL3) -ge 2.0) {
            $hasX3D = $true
            $vCacheMask = ($ccds | Where-Object { $_.L3SizeBytes -eq $maxL3 } |
                           Select-Object -First 1).LogicalProcessorMask
        }
    }

    # P/E core classification by RELATIVE efficiency class ranking, not hardcoded 0/1.
    # Per MS Learn: "A core with a higher value for the efficiency class has intrinsically
    # greater performance and less efficiency." Future Intel hybrids (e.g. Core Ultra with
    # P + E + LP-E) may have 3+ classes — ranking is forward-compatible.
    if ($native.IsHybrid) {
        $maxEff = ($native.PhysicalCores | Measure-Object -Property EfficiencyClass -Maximum).Maximum
        $pCores = @($native.PhysicalCores | Where-Object { $_.EfficiencyClass -eq $maxEff })
        $eCores = @($native.PhysicalCores | Where-Object { $_.EfficiencyClass -ne $maxEff })
    } else {
        $pCores = @($native.PhysicalCores)
        $eCores = @()
    }

    [pscustomobject]@{
        CpuName                = $cpuName
        Vendor                 = $vendor
        IsHybrid               = [bool]$native.IsHybrid
        TotalLogicalProcessors = [int]$native.TotalLogicalProcessors
        PhysicalCores          = @($native.PhysicalCores)
        PCores                 = $pCores
        ECores                 = $eCores
        Ccds                   = $ccds
        HasX3DVCache           = $hasX3D
        VCacheCcdMask          = $vCacheMask
    }
}

function Show-CpuTopology {
    param([Parameter(ValueFromPipeline)][object]$Topology)
    if (-not $Topology) { $Topology = Get-CpuTopology }

    $mb = { param($b) '{0:N2} MB' -f ($b / 1MB) }

    Write-Host ''
    Write-Host '=== CPU Topology ===' -ForegroundColor Cyan
    Write-Host ('CPU    : {0}' -f $Topology.CpuName)
    Write-Host ('Vendor : {0}  |  Hybrid: {1}  |  Total LPs: {2}' -f `
        $Topology.Vendor,
        $(if ($Topology.IsHybrid) { 'Yes' } else { 'No' }),
        $Topology.TotalLogicalProcessors)
    Write-Host ''
    Write-Host 'Physical cores:' -ForegroundColor Cyan

    foreach ($c in $Topology.PhysicalCores) {
        $kind = if ($Topology.IsHybrid) {
            if ($c.EfficiencyClass -gt 0) { 'P-core' } else { 'E-core' }
        } else { 'Core' }
        $smt  = if ($c.HasSmt) { 'SMT' } else { '   ' }
        $lps  = ($c.LogicalProcessors -join ',')
        Write-Host ('  [{0,2}] {1,-6} {2}   LPs: {3}' -f $c.Index, $kind, $smt, $lps)
    }

    if ($Topology.Ccds.Count -gt 0) {
        Write-Host ''
        Write-Host 'L3 cache groupings (CCDs):' -ForegroundColor Cyan
        for ($i = 0; $i -lt $Topology.Ccds.Count; $i++) {
            $ccd = $Topology.Ccds[$i]
            $marker = if ($Topology.HasX3DVCache -and $ccd.LogicalProcessorMask -eq $Topology.VCacheCcdMask) {
                '  *** V-CACHE CCD ***'
            } else { '' }
            Write-Host ('  CCD {0}: L3 = {1}  LPs: {2}{3}' -f `
                $i, (& $mb $ccd.L3SizeBytes), ($ccd.LogicalProcessors -join ','), $marker)
        }
    }

    if ($Topology.Vendor -eq 'AMD') {
        Write-Host ''
        if ($Topology.HasX3DVCache) {
            Write-Host ('AMD X3D V-Cache CCD detected. Mask: 0x{0:X}' -f $Topology.VCacheCcdMask) `
                -ForegroundColor Green
        } else {
            Write-Host 'AMD X3D V-Cache CCD: not detected (single-CCD or non-X3D part).' `
                -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}
