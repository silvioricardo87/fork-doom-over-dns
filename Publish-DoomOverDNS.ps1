#Requires -Version 5.1
<#
.SYNOPSIS
    Uploads managed-doom's publish output and DOOM1.WAD to Cloudflare DNS TXT records.

.DESCRIPTION
    Expects:
      1. A 'dotnet publish' output directory from managed-doom (net8.0, framework-dependent).
      2. The DOOM1.WAD (or other WAD) file.

    Creates two DNS stripe prefixes:
      doom-wad   → the WAD file (GZip compressed)
      doom-libs  → ZIP bundle of all managed DLLs from the publish directory (GZip compressed)

    Run once. After uploading, anyone with Start-DoomOverDNS.ps1 and the primary zone name
    can play Doom — no installer, no API key, no local files, nothing written to disk.

.PARAMETER PublishDir
    Path to the 'dotnet publish' output directory.

.PARAMETER WadPath
    Path to the WAD file (e.g. DOOM1.WAD).

.PARAMETER Zones
    Ordered array of Cloudflare DNS zones to stripe across.
    Estimate: 6 zones should comfortably cover DOOM1.WAD + all DLLs with compression.

.PARAMETER WadPrefix
    DNS prefix for the WAD stripe. Default: 'doom-wad'.

.PARAMETER LibsPrefix
    DNS prefix for the managed DLL bundle. Default: 'doom-libs'.

.PARAMETER Force
    Overwrite existing DNS records without prompting.

.EXAMPLE
    # First build managed-doom (from the managed-doom directory):
    #   dotnet publish ManagedDoom/ManagedDoom.csproj -c Release -f net8.0 -o publish-out
    #
    # Then upload everything:
    .\Publish-DoomOverDNS.ps1 `
        -PublishDir 'managed-doom\publish-out' `
        -WadPath    'DOOM1.WAD' `
        -Zones      @('doomdns.wtf')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$PublishDir,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$WadPath,

    [Parameter(Mandatory)]
    [string[]]$Zones,

    [string]$WadPrefix  = 'doom-wad',
    [string]$LibsPrefix = 'doom-libs',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -Assembly 'System.IO.Compression'
Add-Type -Assembly 'System.IO.Compression.FileSystem'

# ── Import TXTRecords module ───────────────────────────────────────────────────
$modulePath = Join-Path $PSScriptRoot 'TXTRecords\TXTRecords.psm1'
if (-not (Get-Module -Name TXTRecords)) {
    Import-Module $modulePath
}

# Credentials must be set before calling this script via Set-CFCredential

$publishDir = (Resolve-Path $PublishDir).Path

# ── Step 1: Bundle managed DLLs into a ZIP in memory ─────────────────────────
Write-Host ''
Write-Host '=== Step 1: Building managed DLL bundle ===' -ForegroundColor Magenta

# Collect all managed assemblies from the publish root (not runtimes/ subdirs)
$dllFiles = Get-ChildItem -Path $publishDir -Filter '*.dll' -File
$exeFiles = Get-ChildItem -Path $publishDir -Filter '*.exe' -File

$managedFiles = @()
foreach ($f in ($dllFiles + $exeFiles)) {
    $managedFiles += $f
}

Write-Host ("  Found {0} file(s) to bundle:" -f $managedFiles.Count) -ForegroundColor Cyan
foreach ($f in $managedFiles) {
    Write-Host ("    {0} ({1:N0} KB)" -f $f.Name, ($f.Length / 1KB)) -ForegroundColor DarkGray
}

# Create ZIP in memory
$zipMs     = [System.IO.MemoryStream]::new()
$zipArchive = [System.IO.Compression.ZipArchive]::new($zipMs, [System.IO.Compression.ZipArchiveMode]::Create, $true)

foreach ($f in $managedFiles) {
    $entry  = $zipArchive.CreateEntry($f.Name, [System.IO.Compression.CompressionLevel]::Optimal)
    $src    = [System.IO.File]::OpenRead($f.FullName)
    $dst    = $entry.Open()
    $src.CopyTo($dst)
    $dst.Dispose()
    $src.Dispose()
}

$zipArchive.Dispose()
$zipBytes = $zipMs.ToArray()
$zipMs.Dispose()

Write-Host ("  Bundle: {0:N0} KB (uncompressed), ready to upload." -f ($zipBytes.Length / 1KB)) -ForegroundColor Green

# Write bundle to a temp file so Publish-TXTStripe can read it
# (module expects a file path; we remove it after upload)
$bundleTmp = Join-Path $env:TEMP "doom-libs-bundle-$([System.Diagnostics.Process]::GetCurrentProcess().Id).zip"
[System.IO.File]::WriteAllBytes($bundleTmp, $zipBytes)

# ── Step 2: Upload WAD ─────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Step 2: Uploading WAD ===' -ForegroundColor Magenta
Write-Host "  Prefix: $WadPrefix  Zones: $($Zones -join ', ')" -ForegroundColor Cyan

$upParams = @{
    Path          = (Resolve-Path $WadPath).Path
    Zones         = $Zones
    Prefix        = $WadPrefix
    Compress      = $true
}
if ($Force) { $upParams['Force'] = $true }

Publish-TXTStripe @upParams

# ── Step 3: Upload managed DLL bundle ─────────────────────────────────────────
Write-Host ''
Write-Host '=== Step 3: Uploading managed DLL bundle ===' -ForegroundColor Magenta
Write-Host "  Prefix: $LibsPrefix" -ForegroundColor Cyan

try {
    $libParams = @{
        Path          = $bundleTmp
        Zones         = $Zones
        Prefix        = $LibsPrefix
        Compress      = $true
    }
    if ($Force) { $libParams['Force'] = $true }

    Publish-TXTStripe @libParams
} finally {
    Remove-Item $bundleTmp -ErrorAction SilentlyContinue
}

# ── Done ───────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '✓ All uploads complete!' -ForegroundColor Green
Write-Host ''
Write-Host 'To play from DNS (on any Windows machine with PowerShell 7+):' -ForegroundColor Cyan
Write-Host "  .\Start-DoomOverDNS.ps1 -PrimaryZone '$($Zones[0])'" -ForegroundColor White
