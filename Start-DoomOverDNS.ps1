#Requires -Version 7.0
<#
.SYNOPSIS
    DOOM Over DNS — loads Doom entirely from DNS TXT records and runs it in-process — no installer required.

.DESCRIPTION
    Standalone script. Fetches three things from DNS, all credential-free:

      doom-wad   → DOOM1.WAD bytes        → MemoryStream 
      doom-libs  → ZIP of managed DLLs    → Assembly::Load() in-process

    Then calls ManagedDoom.Silk.SilkProgram.RunFromStream() via reflection.
    
    Requirements:
      - PowerShell 7+ (uses .NET 8 runtime)
      - .NET 8 runtime (comes with PowerShell 7.4)
      - Windows (Win32 windowing via P/Invoke)
      - Internet access to public DNS

.PARAMETER WadPrefix
    DNS prefix for the WAD stripe (default: 'doom-wad').

.PARAMETER LibsPrefix
    DNS prefix for the managed DLL bundle stripe (default: 'doom-libs').

.PARAMETER PrimaryZone
    The first zone in each stripe — where stripe-meta records live.

.PARAMETER WadName
    WAD type hint for game mode detection: 'doom1' (shareware), 'doom' (retail), 'doom2'.
    Default: 'doom1'.

.PARAMETER DnsServer
    Optional DNS resolver IP (e.g. '1.1.1.1'). Useful if records haven't propagated yet.


.PARAMETER DoomArgs
    Extra arguments forwarded to managed-doom (e.g. '-warp 1 1 -skill 4').

.EXAMPLE
    .\Start-DoomOverDNS.ps1 -PrimaryZone 'doomdns.wtf'

#>
[CmdletBinding()]
param(
    [string]$WadPrefix   = 'doom-wad',
    [string]$LibsPrefix  = 'doom-libs',

    [Parameter(Mandatory)]
    [string]$PrimaryZone,

    [ValidateSet('doom1','doom','doom2','plutonia','tnt')]
    [string]$WadName = 'doom1',

    [string]$DnsServer,


    [string]$DoomArgs = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -Assembly 'System.IO.Compression'
Add-Type -Assembly 'System.IO.Compression.FileSystem'

# ── DNS resolution helper (no module dependency) ──────────────────────────────
function Resolve-TXT ([string]$Name) {
    $params = @{ Name = $Name; Type = 'TXT'; ErrorAction = 'Stop' }
    if ($DnsServer) { $params['Server'] = $DnsServer }
    try {
        $result = Resolve-DnsName @params
        return ($result | Where-Object { $_.Type -eq 'TXT' } | Select-Object -First 1).Strings -join ''
    } catch { throw "DNS resolution failed for '$Name': $_" }
}

function Get-StripeBytes ([string]$Prefix) {
    $metaName = "$Prefix-stripe-meta.$PrimaryZone"
    Write-Host "  Querying: $metaName" -ForegroundColor DarkCyan

    $metaRaw = Resolve-TXT -Name $metaName
    try   { $meta = $metaRaw | ConvertFrom-Json }
    catch { throw "stripe-meta '$metaName' is not valid JSON. Raw: $metaRaw" }

    $totalChunks   = [int]$meta.chunks
    $zones         = @($meta.zones)
    # Support variable per-zone capacities (new) and uniform chunks_per_zone (old)
    if ($meta.PSObject.Properties['zone_capacities'] -and $meta.zone_capacities) {
        $zoneCapacities = @($meta.zone_capacities | ForEach-Object { [int]$_ })
    } else {
        $cpz = [int]$meta.chunks_per_zone
        $zoneCapacities = @($zones | ForEach-Object { $cpz })
    }
    $zoneStarts = [int[]]::new($zones.Count)
    $zcum = 0
    for ($j = 0; $j -lt $zones.Count; $j++) { $zoneStarts[$j] = $zcum; $zcum += $zoneCapacities[$j] }
    $isCompressed  = [bool]($meta.PSObject.Properties['compressed'] -and $meta.compressed)
    $expectedHash  = $meta.sha256

    Write-Host ("  {0:N0} chunks across {1} zone(s){2}" -f $totalChunks, $zones.Count, $(if ($isCompressed) { ' [GZip]' } else { '' })) -ForegroundColor DarkCyan

    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $totalChunks; $i++) {
        $zIdx = $zones.Count - 1
        for ($j = 0; $j -lt $zones.Count; $j++) { if ($i -lt $zoneStarts[$j] + $zoneCapacities[$j]) { $zIdx = $j; break } }
        $zone = $zones[$zIdx]
        $chunk = Resolve-TXT -Name "$Prefix-$i.$zone"
        if ([string]::IsNullOrEmpty($chunk)) { throw "Chunk $i of '$Prefix' returned empty." }
        $sb.Append($chunk) | Out-Null

        if ($i % 50 -eq 0 -or $i -eq $totalChunks - 1) {
            Write-Progress -Activity "Fetching $Prefix from DNS" `
                -Status ("Chunk {0}/{1}" -f ($i + 1), $totalChunks) `
                -PercentComplete ([Math]::Round(($i / $totalChunks) * 100))
        }
    }
    Write-Progress -Activity "Fetching $Prefix from DNS" -Completed

    $rawBytes = [Convert]::FromBase64String($sb.ToString())

    if ($isCompressed) {
        $cin  = [System.IO.MemoryStream]::new($rawBytes, $false)
        $cout = [System.IO.MemoryStream]::new()
        $gz   = [System.IO.Compression.GZipStream]::new($cin, [System.IO.Compression.CompressionMode]::Decompress)
        $gz.CopyTo($cout)
        $gz.Dispose()
        $rawBytes = $cout.ToArray()
    }

    # Verify hash (always against the decompressed/original bytes)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    $actual = ($sha.ComputeHash($rawBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($actual -ne $expectedHash) {
        Write-Warning "Hash mismatch for '$Prefix'! Data may be corrupt."
    } else {
        Write-Host "  ✓ Hash verified." -ForegroundColor Green
    }

    return ,$rawBytes
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '______  _____  _____ ___  ___' -ForegroundColor DarkRed
Write-Host '|  _  \|  _  ||  _  ||  \/  |' -ForegroundColor Red
Write-Host '| | | || | | || | | || .  . |' -ForegroundColor Yellow
Write-Host '| | | || | | || | | || |\/| |' -ForegroundColor Yellow
Write-Host '| |/ / \ \_/ /\ \_/ /| |  | |' -ForegroundColor Red
Write-Host '|___/   \___/  \___/ \_|  |_/' -ForegroundColor DarkRed
Write-Host ''
Write-Host ' _____  _   _  _____ ______' -ForegroundColor DarkRed
Write-Host '|  _  || | | ||  ___|| ___ \' -ForegroundColor Red
Write-Host '| | | || | | || |__  | |_/ /' -ForegroundColor Yellow
Write-Host '| | | || | | ||  __| |    /' -ForegroundColor Yellow
Write-Host '\ \_/ /\ \_/ /| |___ | |\ \' -ForegroundColor Red
Write-Host ' \___/  \___/ \____/ \_| \_|' -ForegroundColor DarkRed
Write-Host ''
Write-Host '______  _   _  _____' -ForegroundColor DarkRed
Write-Host '|  _  \| \ | |/  ___|' -ForegroundColor Red
Write-Host '| | | ||  \| |\ `--.' -ForegroundColor Yellow
Write-Host '| | | || . ` | `--. \' -ForegroundColor Yellow
Write-Host '| |/ / | |\  |/\__/ /' -ForegroundColor Red
Write-Host '|___/  \_| \_/\____/' -ForegroundColor DarkRed
Write-Host ''

# ── Step 1: Fetch managed DLL bundle → load into shared AssemblyLoadContext ────
Write-Host ''
Write-Host '=== Step 1: Managed DLL bundle ===' -ForegroundColor Magenta
Write-Host "  Fetching from DNS prefix '$LibsPrefix'..." -ForegroundColor Cyan

$libsBytes = Get-StripeBytes -Prefix $LibsPrefix   # returns a ZIP

# Load all managed DLLs into the Default AssemblyLoadContext via LoadFromStream (public API).
# Everything lands in one shared type universe — no Add-Type compilation, no disk writes,
# no custom ALC subclass needed. Dependencies resolve from cache since all assemblies are
# pre-loaded before RunFromStream is called.
$_defaultAlc = [System.Runtime.Loader.AssemblyLoadContext]::Default

$zipStream = [System.IO.MemoryStream]::new($libsBytes, $false)
$zip       = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Read)

$doomAssembly = $null

foreach ($entry in $zip.Entries) {
    if ($entry.Name -notlike '*.dll' -and $entry.Name -notlike '*.exe') { continue }
    if ($entry.Name -like '*.Native*' -or $entry.Name -like 'glfw*') { continue }

    $ms = [System.IO.MemoryStream]::new()
    $entry.Open().CopyTo($ms)
    $dllBytes   = $ms.ToArray()
    $simpleName = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)

    try {
        $asm = $_defaultAlc.LoadFromStream([System.IO.MemoryStream]::new($dllBytes))
        Write-Host ("  Loaded: {0} ({1:N0} KB)" -f $simpleName, ($dllBytes.Length / 1KB)) -ForegroundColor DarkGray
        if ($simpleName -eq 'managed-doom') { $doomAssembly = $asm }
    } catch {
        Write-Verbose "  Skipped '$($entry.Name)': $_"
    }
}

$zip.Dispose()

if ($null -eq $doomAssembly) {
    throw "managed-doom assembly was not found in the '$LibsPrefix' bundle."
}

Write-Host "  All assemblies loaded into Default ALC." -ForegroundColor Green

# ── Step 2: Fetch WAD → MemoryStream (never written to disk) ──────────────────
Write-Host ''
Write-Host '=== Step 2: WAD file ===' -ForegroundColor Magenta
Write-Host "  Fetching from DNS prefix '$WadPrefix'..." -ForegroundColor Cyan

$wadBytes  = Get-StripeBytes -Prefix $WadPrefix
$wadStream = [System.IO.MemoryStream]::new($wadBytes, $false)

Write-Host ("  WAD in memory: {0:N0} bytes." -f $wadBytes.Length) -ForegroundColor Green

# ── Step 3: Launch Doom in-process via reflection ─────────────────────────────
Write-Host ''
Write-Host '=== Step 3: Launching Doom ===' -ForegroundColor Magenta

$silkProgramType = $doomAssembly.GetType('ManagedDoom.Silk.SilkProgram')
if ($null -eq $silkProgramType) {
    throw "Could not find ManagedDoom.Silk.SilkProgram in the loaded assembly."
}

$runMethod = $silkProgramType.GetMethod('RunFromStream')
if ($null -eq $runMethod) {
    throw "Could not find SilkProgram.RunFromStream. Ensure managed-doom was patched correctly."
}

# Build args array from user extras
$extraArgs = [System.Collections.Generic.List[string]]::new()
if ($DoomArgs) { $extraArgs.AddRange($DoomArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)) }

Write-Host "  Calling SilkProgram.RunFromStream (WAD: $WadName, no audio)..." -ForegroundColor Cyan
Write-Host ''

try {
    $runMethod.Invoke($null, @($wadStream, $WadName, $extraArgs.ToArray()))
} catch [System.Reflection.TargetInvocationException] {
    throw $_.Exception.InnerException
} finally {
    $wadStream.Dispose()
}

Write-Host ''
Write-Host 'Doom exited.' -ForegroundColor Green
