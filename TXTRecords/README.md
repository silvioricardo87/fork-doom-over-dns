# TXTRecords

Store and retrieve binary files using Cloudflare DNS TXT records.

TXTRecords encodes any file into Base64 chunks and writes each chunk as a numbered DNS TXT record under a subdomain prefix you choose. Retrieval requires no API credentials — any machine with public DNS access can extract the file using the built-in `Resolve-DnsName` cmdlet.

> **This is a proof-of-concept.** DNS was not designed as a file store. See [Limitations](#limitations) before uploading anything large.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Concepts](#concepts)
  - [Single-Zone Records vs Multi-Zone Stripes](#single-zone-records-vs-multi-zone-stripes)
  - [Chunk Sizing](#chunk-sizing)
  - [Zone Capacity](#zone-capacity)
  - [Compression](#compression)
  - [Integrity Verification](#integrity-verification)
- [Credential Management](#credential-management)
  - [Set-CFCredential](#set-cfcredential)
  - [Get-CFZone](#get-cfzone)
- [Single-Zone Functions](#single-zone-functions)
  - [Publish-TXTRecord](#publish-txtrecord)
  - [Get-TXTRecord](#get-txtrecord)
  - [Get-TXTRecordBytes](#get-txtrecordbytes)
  - [Remove-TXTRecord](#remove-txtrecord)
  - [Get-TXTRecordList](#get-txtrecordlist)
- [Multi-Zone Stripe Functions](#multi-zone-stripe-functions)
  - [Publish-TXTStripe](#publish-txtstripe)
  - [Get-TXTStripe](#get-txtstripe)
  - [Get-TXTStripeBytes](#get-txtstripeBytes)
  - [Remove-TXTStripe](#remove-txtstripe)
  - [Get-TXTStripeList](#get-txtstripelist)
- [Upload Behavior](#upload-behavior)
  - [Rate Limiting](#rate-limiting)
  - [Parallel Uploads](#parallel-uploads)
  - [Cancellation and Rollback](#cancellation-and-rollback)
  - [Resuming Interrupted Uploads](#resuming-interrupted-uploads)
- [Extracting Without the Module](#extracting-without-the-module)
- [Limitations](#limitations)

---

## Requirements

- PowerShell 5.1 or later (Windows)
- A Cloudflare account with at least one zone
- A Cloudflare API token with **DNS Edit** permissions (upload/delete only — extraction is credential-free)

---

## Installation

```powershell
Import-Module .\TXTRecords\TXTRecords.psm1
```

The module is self-contained — no external dependencies. It uses `Invoke-RestMethod` for Cloudflare API calls and `Resolve-DnsName` for credential-free extraction.

---

## Quick Start

### Single-zone (small files)

```powershell
# 1. Store your API token (once per session)
Set-CFCredential -ApiToken 'your_token_here'

# 2. Upload a file
Publish-TXTRecord -Path 'C:\Videos\clip.mp4' -Zone 'example.com' -Prefix 'clip'

# 3. Extract it (no API key needed — works from any machine)
Get-TXTRecord -Prefix 'clip' -Zone 'example.com' -Path 'C:\Output\clip.mp4'

# 4. Clean up when done
Remove-TXTRecord -Zone 'example.com' -Prefix 'clip'
```

### Multi-zone stripe (large files, compression, multi-zone distribution)

```powershell
# 1. Upload with GZip compression across multiple zones
Publish-TXTStripe -Path 'C:\Data\archive.bin' -Zones @('zone1.com', 'zone2.com') `
    -Prefix 'archive' -Compress

# 2. Extract (only the primary zone name is needed)
Get-TXTStripe -Prefix 'archive' -PrimaryZone 'zone1.com' -Path 'C:\Output\archive.bin'

# 3. Or load directly into memory without writing to disk
$bytes = Get-TXTStripeBytes -Prefix 'archive' -PrimaryZone 'zone1.com'

# 4. Clean up (reads stripe-meta to discover all zones automatically)
Remove-TXTStripe -Prefix 'archive' -PrimaryZone 'zone1.com'
```

---

## Concepts

### Single-Zone Records vs Multi-Zone Stripes

The module provides two sets of functions:

| | Single-Zone (`*-TXTRecord`) | Multi-Zone (`*-TXTStripe`) |
|---|---|---|
| **Zones** | One zone only | One or more zones, striped sequentially |
| **Metadata record** | `<prefix>-meta.<zone>` | `<prefix>-stripe-meta.<zone[0]>` |
| **Compression** | Not supported | Optional GZip via `-Compress` |
| **Metadata format** | `{ filename, chunks, sha256, size }` | `{ filename, chunks, sha256, size, zones, zone_capacities, compressed }` |
| **Best for** | Small files that fit in a single zone | Large files, or when compression is needed |

Both share the same underlying chunk format (Base64 TXT records with sequential indices) and the same rate-limiting infrastructure. Single-zone functions are simpler — use them when a file fits in one zone and compression isn't needed.

### Chunk Sizing

Each TXT record stores up to **2,000 characters** of Base64 data. Cloudflare supports up to 2,048 characters per TXT record value; the 48-character margin accounts for DNS overhead.

Base64 encodes 3 bytes as 4 characters, so each record holds **1,500 bytes** of binary data. A 1 MB file produces approximately **700 TXT records** (or fewer with GZip compression enabled).

### Zone Capacity

Cloudflare imposes per-zone record limits that vary by plan:

| Cloudflare Plan | Record Limit | Safe Data Chunks | Notes |
|---|---|---|---|
| Free | 200 | 185 | 15-record buffer for NS, SOA, and other overhead |
| Pro | 3,500 | 3,400 | 100-record buffer |
| Business | 3,500 | 3,400 | Same as Pro |
| Enterprise | 3,500 | 3,400 | Conservative default |

The stripe functions auto-detect each zone's plan via the Cloudflare API and set per-zone capacities accordingly. You can mix Free and Pro zones — the module fills each to its safe limit before moving to the next.

**Important:** Each zone must be a separately registered root domain delegated to Cloudflare. Subdomains cannot be managed as independent zones. You cannot use `a.example.com` and `b.example.com` as separate zones.

### Compression

The `-Compress` switch on `Publish-TXTStripe` GZip-compresses the file in memory before Base64-encoding and chunking. This can dramatically reduce chunk count:

| File Type | Raw Size | Compressed | Reduction |
|---|---|---|---|
| Binary game data | 4.0 MB | 1.7 MB | 58% |
| DLL bundle (ZIP) | ~4.4 MB | ~1.1 MB | 75% |
| Native library | ~0.23 MB | ~0.07 MB | 70% |

Compression is recorded in the `stripe-meta` record (`"compressed": true`) and detected automatically on extraction — the caller doesn't need to know whether a stripe was compressed.

Compression is not available for single-zone `Publish-TXTRecord` uploads.

### Integrity Verification

Every upload (both single-zone and stripe) computes a SHA-256 hash of the original file bytes and stores it in the metadata record. On extraction, the hash is recomputed after reassembly (and decompression, if applicable) and compared. A mismatch produces a warning — the file is still written/returned, but the caller is alerted that data may be corrupt.

For stripe uploads, the hash is always computed against the **original, uncompressed** bytes, ensuring the full pipeline (DNS fetch → Base64 decode → GZip decompress) is verified end-to-end.

---

## Credential Management

### `Set-CFCredential`

Stores your Cloudflare API token in memory for the current session. The token is never written to disk.

```powershell
Set-CFCredential -ApiToken 'your_token_here'

# Or prompt securely (token won't echo to the terminal)
$token = Read-Host 'Cloudflare API Token' -AsSecureString
Set-CFCredential -ApiToken $token
```

Accepts either a plain `[string]` or a `[SecureString]`. If a `SecureString` is passed, it is converted to plain text internally (required for HTTP `Authorization` headers).

**Getting a token:**
1. Log in to [dash.cloudflare.com](https://dash.cloudflare.com)
2. My Profile → API Tokens → Create Token
3. Use the **Edit zone DNS** template
4. Scope it to the specific zone(s) you need
5. Copy the token — it is only shown once

---

### `Get-CFZone`

Lists all DNS zones accessible with your token. Useful for finding the exact zone name and confirming your token has access.

```powershell
Get-CFZone
```

Returns objects with `Name`, `Id`, `Status`, and `Plan` properties. Handles pagination automatically for accounts with many zones.

---

## Single-Zone Functions

These functions store and retrieve files within a single Cloudflare DNS zone.

### `Publish-TXTRecord`

Uploads a file to DNS TXT records in a single zone.

```powershell
Publish-TXTRecord -Path <file> -Zone <zone> -Prefix <prefix> [-TTL <seconds>] [-Force] [-Resume]
```

| Parameter | Description |
|---|---|
| `-Path` | Path to the source file. Any file type is supported. |
| `-Zone` | DNS zone to publish into (e.g. `example.com`). |
| `-Prefix` | Subdomain prefix for record names. Letters, numbers, and hyphens only. |
| `-TTL` | DNS TTL in seconds. Default `1` (Cloudflare automatic). |
| `-Force` | Skip the confirmation prompt when overwriting existing records. |
| `-Resume` | Resume an interrupted upload (see [Resuming Interrupted Uploads](#resuming-interrupted-uploads)). |

**Record layout:**

| Record name | Contents |
|---|---|
| `<prefix>-meta.<zone>` | JSON: `{ filename, chunks, sha256, size }` |
| `<prefix>-0.<zone>` | Base64 chunk 0 (up to 2000 chars) |
| `<prefix>-1.<zone>` | Base64 chunk 1 |
| … | … |

**Examples:**

```powershell
# Basic upload
Publish-TXTRecord -Path 'C:\clip.mp4' -Zone 'example.com' -Prefix 'clip'

# Overwrite existing records without prompting
Publish-TXTRecord -Path 'C:\clip.mp4' -Zone 'example.com' -Prefix 'clip' -Force

# Resume after an interruption
Publish-TXTRecord -Path 'C:\clip.mp4' -Zone 'example.com' -Prefix 'clip' -Resume
```

On a fresh upload (no `-Resume`), all existing records with the same prefix are deleted before uploading. The `-Force` switch suppresses the confirmation prompt for this deletion.

For files larger than 500 chunks, a warning is printed with an estimated upload time.

---

### `Get-TXTRecord`

Extracts a file from DNS TXT records and writes it to disk. **No API credentials required** — uses `Resolve-DnsName` which is built into Windows.

```powershell
Get-TXTRecord -Prefix <prefix> -Zone <zone> [-Path <output>] [-DnsServer <ip>] [-Force]
```

| Parameter | Description |
|---|---|
| `-Prefix` | The prefix used when the file was uploaded. |
| `-Zone` | The DNS zone containing the records. |
| `-Path` | Output file path. If omitted, uses the original filename from the metadata record in the current directory. |
| `-DnsServer` | Optional DNS resolver IP (e.g. `'1.1.1.1'`). Uses the system default if omitted. |
| `-Force` | Overwrite the output file if it already exists. |

```powershell
# Extract using system DNS
Get-TXTRecord -Prefix 'clip' -Zone 'example.com' -Path 'C:\Output\clip.mp4'

# Force Cloudflare's public resolver (useful before propagation)
Get-TXTRecord -Prefix 'clip' -Zone 'example.com' -Path '.\clip.mp4' -DnsServer '1.1.1.1'

# Use the original filename from metadata
Get-TXTRecord -Prefix 'clip' -Zone 'example.com'
```

The output directory is created automatically if it doesn't exist. The SHA-256 hash is verified after reassembly — a warning is printed on mismatch.

---

### `Get-TXTRecordBytes`

Identical to `Get-TXTRecord` but returns the file as a `[byte[]]` instead of writing to disk. Useful for in-memory processing.

```powershell
$bytes = Get-TXTRecordBytes -Prefix 'clip' -Zone 'example.com'
$bytes = Get-TXTRecordBytes -Prefix 'clip' -Zone 'example.com' -DnsServer '1.1.1.1'
```

| Parameter | Description |
|---|---|
| `-Prefix` | The prefix used when the file was uploaded. |
| `-Zone` | The DNS zone containing the records. |
| `-DnsServer` | Optional DNS resolver IP. |

No API credentials required. SHA-256 is verified before returning.

---

### `Remove-TXTRecord`

Deletes all TXT records associated with a stored file, including the metadata record.

```powershell
Remove-TXTRecord -Zone <zone> -Prefix <prefix> [-Force]
```

| Parameter | Description |
|---|---|
| `-Zone` | The DNS zone containing the records. |
| `-Prefix` | The prefix of the file to remove. |
| `-Force` | Skip the confirmation prompt. |

```powershell
# With confirmation prompt
Remove-TXTRecord -Zone 'example.com' -Prefix 'clip'

# Skip prompt
Remove-TXTRecord -Zone 'example.com' -Prefix 'clip' -Force
```

Deletion runs in parallel with the same rate-limiting as uploads (3 concurrent, 3 req/sec, 429-aware backoff). Records that fail to delete are reported as warnings — re-run to retry any stragglers.

Reports a summary when finished: how many records were successfully deleted and how many failed.

---

### `Get-TXTRecordList`

Lists all files currently stored in a zone (by scanning for `<prefix>-meta` records).

```powershell
Get-TXTRecordList -Zone 'example.com'
```

Requires API credentials. Returns objects with `Prefix`, `Filename`, `Chunks`, `Size`, `SHA256`, and `Record` properties.

---

## Multi-Zone Stripe Functions

These functions distribute files across one or more Cloudflare DNS zones. They support GZip compression, variable per-zone capacities, and automatic zone plan detection.

### `Publish-TXTStripe`

Uploads a file across one or more DNS zones with optional GZip compression.

```powershell
Publish-TXTStripe -Path <file> -Zones <zone[]> -Prefix <prefix>
    [-ChunksPerZone <n>] [-TTL <seconds>] [-Force] [-Resume] [-Compress]
```

| Parameter | Description |
|---|---|
| `-Path` | Path to the source file. |
| `-Zones` | Ordered array of DNS zone names to stripe across (at least 2). |
| `-Prefix` | Subdomain prefix. Letters, numbers, and hyphens only. |
| `-ChunksPerZone` | Manual override for per-zone capacity. Default `0` (auto-detect from zone plan). |
| `-TTL` | DNS TTL in seconds. Default `1` (Cloudflare automatic). |
| `-Force` | Skip confirmation prompt when overwriting. |
| `-Resume` | Resume an interrupted upload. |
| `-Compress` | GZip-compress the file before encoding. |

**Record layout:**

A single `stripe-meta` record is written to the first zone:

```
<prefix>-stripe-meta.<zones[0]>  →  JSON metadata
```

Data chunks use global indices and are distributed sequentially:

```
<prefix>-0.<zones[0]>     through  <prefix>-N.<zones[0]>
<prefix>-(N+1).<zones[1]> through  <prefix>-M.<zones[1]>
...
```

The stripe-meta record contains a JSON manifest with all information needed for extraction:

```json
{
  "filename": "archive.bin",
  "size": 4196020,
  "sha256": "5b2e249b9c5133ec987b3f9cc2...",
  "chunks": 1199,
  "zones": ["zone1.com", "zone2.com"],
  "zone_capacities": [3400, 185],
  "chunks_per_zone": 3400,
  "compressed": true
}
```

| Field | Purpose |
|---|---|
| `chunks` | Total number of data chunks across all zones |
| `zones` | Ordered list of DNS zones containing the chunks |
| `zone_capacities` | Maximum chunks in each zone (may vary — auto-detected from plan) |
| `chunks_per_zone` | Capacity of the first zone (legacy compatibility field) |
| `compressed` | Whether the data was GZip-compressed before encoding |
| `sha256` | SHA-256 hash of the original (uncompressed) file bytes |
| `size` | Original file size in bytes |
| `filename` | Original filename |

**Chunk-to-zone mapping:** Chunks `0` through `zone_capacities[0]-1` are in `zones[0]`, the next `zone_capacities[1]` chunks are in `zones[1]`, and so on. The DNS name for any chunk is `<prefix>-<globalIndex>.<zone>`.

**Auto-detection:** The module queries each zone's Cloudflare plan before uploading and stops resolving zones once cumulative capacity meets the file's needs. If the total capacity is insufficient, the upload fails with a clear error message.

**Examples:**

```powershell
# Upload with compression to a single Pro zone (still requires array syntax)
Publish-TXTStripe -Path 'C:\Data\archive.bin' -Zones @('pro-zone.com', 'overflow.com') `
    -Prefix 'archive' -Compress

# Force overwrite
Publish-TXTStripe -Path 'C:\Data\archive.bin' -Zones @('z1.com', 'z2.com') `
    -Prefix 'archive' -Compress -Force

# Resume an interrupted upload
Publish-TXTStripe -Path 'C:\Data\archive.bin' -Zones @('z1.com', 'z2.com') `
    -Prefix 'archive' -Compress -Resume

# Manual chunks-per-zone override (bypasses plan auto-detection)
Publish-TXTStripe -Path 'C:\Data\archive.bin' -Zones @('z1.com', 'z2.com') `
    -Prefix 'archive' -ChunksPerZone 500
```

---

### `Get-TXTStripe`

Extracts a striped file from DNS and writes it to disk. No API credentials required.

```powershell
Get-TXTStripe -Prefix <prefix> -PrimaryZone <zone> [-Path <output>] [-DnsServer <ip>] [-Force]
```

| Parameter | Description |
|---|---|
| `-Prefix` | The prefix used during upload. |
| `-PrimaryZone` | The first zone in the stripe (where `stripe-meta` lives). |
| `-Path` | Output file path. If omitted, uses the original filename from stripe-meta. |
| `-DnsServer` | Optional DNS resolver IP. |
| `-Force` | Overwrite the output file if it already exists. |

```powershell
Get-TXTStripe -Prefix 'archive' -PrimaryZone 'example.com' -Path 'C:\Output\archive.bin'

# Use Cloudflare's resolver directly
Get-TXTStripe -Prefix 'archive' -PrimaryZone 'example.com' -DnsServer '1.1.1.1'
```

The function reads `stripe-meta` to discover the full zone list, chunk count, and compression flag. Decompression is automatic. The caller only needs to know the prefix and primary zone.

---

### `Get-TXTStripeBytes`

Identical to `Get-TXTStripe` but returns the file as a `[byte[]]` instead of writing to disk.

```powershell
$bytes = Get-TXTStripeBytes -Prefix 'archive' -PrimaryZone 'example.com'
$bytes = Get-TXTStripeBytes -Prefix 'archive' -PrimaryZone 'example.com' -DnsServer '1.1.1.1'
```

| Parameter | Description |
|---|---|
| `-Prefix` | The prefix used during upload. |
| `-PrimaryZone` | The first zone in the stripe. |
| `-DnsServer` | Optional DNS resolver IP. |

No API credentials required. GZip decompression and SHA-256 verification happen automatically before returning.

---

### `Remove-TXTStripe`

Deletes all DNS records for a stripe across all its zones. Requires API credentials.

```powershell
Remove-TXTStripe -Prefix <prefix> -PrimaryZone <zone> [-Force]
```

| Parameter | Description |
|---|---|
| `-Prefix` | The prefix used during upload. |
| `-PrimaryZone` | The first zone in the stripe. |
| `-Force` | Skip the confirmation prompt. |

```powershell
# With confirmation
Remove-TXTStripe -Prefix 'archive' -PrimaryZone 'example.com'

# Skip prompt
Remove-TXTStripe -Prefix 'archive' -PrimaryZone 'example.com' -Force
```

The function reads `stripe-meta` to discover the full zone list, then deletes all matching chunk records from each zone. The `stripe-meta` record itself is deleted last. If `stripe-meta` is not found, the function throws an error — use `Remove-TXTRecord` for manual cleanup of individual zones.

---

### `Get-TXTStripeList`

Lists all stripe uploads stored in a primary zone (by scanning for `*-stripe-meta` records).

```powershell
Get-TXTStripeList -PrimaryZone 'example.com'
```

Requires API credentials. Returns objects with `Prefix`, `Filename`, `Size`, `Chunks`, `Zones`, `ChunksPerZone`, and `SHA256` properties.

---

## Upload Behavior

### Rate Limiting

All API operations (upload, delete, resume verification) are automatically throttled to stay within the **Cloudflare free tier limit of 1,200 requests per 5 minutes**:

- Maximum **3 concurrent** in-flight requests at any time
- Sustained rate of **3 requests/second** (180/min — well under the 240/min limit)
- On a `429 Too Many Requests` response, the affected request reads the `Retry-After` header, backs off, and retries automatically
- Retries use **exponential backoff**: 30s → 60s → 120s → 240s → 300s (capped)
- Each chunk is retried up to **5 times** before the module records it as failed

No manual configuration is needed. These constants are at the top of the module if you need to adjust them for a paid plan with higher limits:

```powershell
$Script:CF_MAX_CONCURRENCY       = 3      # simultaneous in-flight requests
$Script:CF_RATE_LIMIT_RPS        = 3.0    # target requests per second
$Script:CF_429_BASE_WAIT         = 30     # seconds to wait on first 429
$Script:CF_429_MAX_WAIT          = 300    # exponential backoff ceiling (seconds)
$Script:CF_MAX_RETRIES           = 5      # retries per chunk before giving up
$Script:CF_RESUME_VERIFY_WINDOW  = 5      # chunks verified around resume boundary
```

### Parallel Uploads

Uploads use a **RunspacePool** for concurrency. Each chunk is uploaded in its own runspace, with a shared token-bucket rate limiter ensuring the aggregate request rate stays within limits. The main thread dispatches jobs and monitors progress — it never queues more than `CF_MAX_CONCURRENCY` jobs at once, so on cancellation there are at most 3 in-flight requests to wait for.

Progress is shown via `Write-Progress` with chunk counts and percentages. For stripe uploads, progress includes the zone index (`Zone 1/3: example.com`).

### Cancellation and Rollback

Pressing **Ctrl+C** during an upload triggers a graceful shutdown:

1. The module intercepts Ctrl+C by setting `[Console]::TreatControlCAsInput = $true` and polling for the key in the dispatch loop — this avoids `PipelineStoppedException` killing the cleanup code
2. No new jobs are dispatched
3. In-flight requests (at most 3) are allowed to complete
4. All record IDs created during the current session are collected
5. Those records are deleted one by one (with progress)
6. The stripe-meta record is also deleted (unless `-Resume` mode was used — in that case, previously uploaded chunks and the existing stripe-meta are left intact)
7. A summary is printed with the count of rolled-back records and a suggestion to re-run with `-Resume`

Rollback is scoped to the current session only. If you previously uploaded 500 chunks, then `-Resume` another 200 and Ctrl+C, only the 200 new chunks are rolled back. The original 500 remain intact.

### Resuming Interrupted Uploads

Both `Publish-TXTRecord` and `Publish-TXTStripe` support a `-Resume` switch for continuing interrupted uploads. The resume process is designed to be fast and safe:

1. **Metadata verification** — The SHA-256 hash in the existing metadata record is compared against the local file. If they don't match, the resume fails immediately with a clear error. This prevents accidentally appending chunks from a different file.

2. **Boundary scan** — All TXT record names in each zone are scanned (one paginated API call per zone) to find the highest existing chunk index. This is a name-only scan — no record content is fetched at this stage.

3. **Boundary window verification** — The last 5 chunks before the upload boundary are content-verified against the expected Base64 values computed from the local file. This detects partially written chunks that might have been created but contain corrupt data (e.g., from a network interruption mid-request).

4. **Resume** — Uploading begins from the first missing or corrupt chunk. All chunks before it are trusted and left untouched. The file stream is seeked to the exact byte offset needed — no re-encoding of skipped chunks.

If all chunks are already present and verified, the function prints a message and returns without uploading anything.

---

## Extracting Without the Module

Because retrieval uses only `Resolve-DnsName` and standard .NET, you can extract a file on any Windows machine with no module installed. Replace `clip`, `example.com`, and `C:\out\clip.mp4` with your prefix, zone, and desired output path:

```powershell
$p='clip';$z='example.com';$o='C:\out\clip.mp4';$m=(Resolve-DnsName "$p-meta.$z" -Type TXT).Strings-join''|ConvertFrom-Json;[IO.File]::WriteAllBytes($o,[Convert]::FromBase64String((-join(0..($m.chunks-1)|%{(Resolve-DnsName "$p-$_.$z" -Type TXT).Strings-join''}))))
```

Expanded for readability:

```powershell
$prefix = 'clip'
$zone   = 'example.com'
$output = 'C:\out\clip.mp4'

# Read metadata
$meta = (Resolve-DnsName "$prefix-meta.$zone" -Type TXT).Strings -join '' | ConvertFrom-Json

# Fetch and concatenate all chunks, then decode and write
$base64 = -join (0..($meta.chunks - 1) | ForEach-Object {
    (Resolve-DnsName "$prefix-$_.$zone" -Type TXT).Strings -join ''
})
[IO.File]::WriteAllBytes($output, [Convert]::FromBase64String($base64))
```

> **Note:** This one-liner only works for uncompressed single-zone uploads (`Publish-TXTRecord`). Stripe uploads with compression require GZip decompression and multi-zone chunk routing — use `Get-TXTStripe` or `Get-TXTStripeBytes` for those.

> **Note:** The expanded form loads the full Base64 string into memory before writing. For very large files this may use several hundred MB of RAM.

---

## Limitations

- **Speed.** At 3 req/sec, a 1 MB file (~700 records) takes roughly 4 minutes to upload. A 4 MB file takes ~7 minutes with GZip compression (reducing ~2,800 records to ~1,200). Upload speed is dominated by Cloudflare API rate limits, not network bandwidth.
- **DNS propagation.** Newly created records may not resolve immediately via public DNS. If extraction fails with missing chunks, wait a few minutes and try again — or use `-DnsServer '1.1.1.1'` to query Cloudflare's resolver directly.
- **Zone record limits.** Cloudflare Free zones hold 200 records (185 safe data chunks). Pro zones hold 3,500 records (3,400 safe chunks). Files exceeding a single zone's capacity must use `Publish-TXTStripe` with multiple zones.
- **Zone clutter.** Large files create thousands of TXT records in your zone. Always run `Remove-TXTRecord` or `Remove-TXTStripe` when done.
- **Not private.** DNS TXT records are publicly queryable. Anyone who knows the prefix and zone can extract the file. If you need privacy, encrypt the file before uploading.
- **Memory usage.** Compressed stripe uploads read the entire file into memory for GZip compression. Extraction also loads the full file into memory. This is fine for files up to tens of megabytes but may be problematic for very large files.
