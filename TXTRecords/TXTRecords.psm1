#Requires -Version 5.1
<#
.SYNOPSIS
    TXTRecords - Store and retrieve binary files using DNS TXT records via Cloudflare.

.DESCRIPTION
    This module encodes binary files (e.g. MP4, images, any file) into Base64 chunks
    and stores each chunk as a numbered DNS TXT record under a chosen subdomain prefix.
    Retrieval can be done either via the Cloudflare API (requires credentials) or via
    the built-in Resolve-DnsName cmdlet (no credentials needed — works from any machine).

    DNS TXT records have a practical limit of 255 bytes per string, but Cloudflare allows
    up to 2048 bytes per TXT record value. This module uses 500-character chunks to stay
    well within limits and to avoid hitting per-record byte caps.

    Record naming convention:
        <prefix>-meta.<zone>    → Stores metadata (filename, total chunks, SHA256 hash)
        <prefix>-0.<zone>       → Chunk 0 (Base64 encoded)
        <prefix>-1.<zone>       → Chunk 1
        ...and so on

    IMPORTANT: DNS is not designed as a file storage medium. This module is a fun
    proof-of-concept / steganographic curiosity. Be mindful of:
      - Cloudflare free tier rate limits (1200 requests / 5 min)
      - DNS propagation delays (records may not resolve immediately)
      - File size: each chunk is ~500 bytes of Base64 ≈ 375 bytes binary.
        A 1 MB file requires ~2730 TXT records. Large files will be slow and
        may hit API rate limits.

.NOTES
    Author: TXTRecords Module
    Requires: PowerShell 5.1+, Cloudflare API Token with DNS Edit permissions
#>

# ──────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ──────────────────────────────────────────────────────────────────────────────

# Maximum Base64 characters stored per TXT record.
# Cloudflare supports up to 2048 bytes, but we keep this conservative so the
# record (including DNS overhead) stays comfortably within limits.
$Script:CHUNK_SIZE = 2000

# Cloudflare API base URL
$Script:CF_API = 'https://api.cloudflare.com/client/v4'

# ── Rate limiting constants (Cloudflare free tier) ─────────────────────────────
# Free tier cap: 1200 requests per 5 minutes = 4 req/sec.
# We target 3 req/sec to leave a 25% headroom buffer, and allow up to 3
# concurrent in-flight requests at once. On a 429, we back off using the
# Retry-After header (or a default) and retry with exponential backoff.
$Script:CF_MAX_CONCURRENCY  = 3      # simultaneous in-flight requests
$Script:CF_RATE_LIMIT_RPS   = 3.0    # target requests per second
$Script:CF_429_BASE_WAIT    = 30     # seconds to wait on first 429
$Script:CF_429_MAX_WAIT     = 300    # cap exponential backoff at 5 minutes
$Script:CF_MAX_RETRIES      = 5      # max retry attempts per chunk before giving up
$Script:CF_RESUME_VERIFY_WINDOW = 5      # chunks to content-verify around the upload boundary on -Resume

# ──────────────────────────────────────────────────────────────────────────────
# INTERNAL HELPERS
# ──────────────────────────────────────────────────────────────────────────────

function Get-CFHeaders {
    <#
    .SYNOPSIS
        Builds the HTTP headers required for Cloudflare API calls.
    .DESCRIPTION
        Reads the API token from the module-level variable $Script:CFApiToken
        (set by Set-CFCredential) and returns a hashtable suitable for
        Invoke-RestMethod's -Headers parameter.
    #>
    if (-not $Script:CFApiToken) {
        throw 'No Cloudflare API token configured. Run Set-CFCredential first.'
    }
    return @{
        'Authorization' = "Bearer $Script:CFApiToken"
        'Content-Type'  = 'application/json'
    }
}

function Get-ZoneId {
    <#
    .SYNOPSIS
        Resolves a DNS zone name (e.g. "example.com") to its Cloudflare Zone ID.
    .PARAMETER Zone
        The DNS zone name as it appears in your Cloudflare dashboard.
    #>
    param([string]$Zone)

    $response = Invoke-RestMethod `
        -Uri     "$Script:CF_API/zones?name=$Zone" `
        -Headers (Get-CFHeaders) `
        -Method  Get

    if (-not $response.success -or $response.result.Count -eq 0) {
        throw "Zone '$Zone' not found in Cloudflare account, or API call failed: $($response.errors | ConvertTo-Json)"
    }
    return $response.result[0].id
}

function Get-ZoneSafeCapacity {
    <#
    .SYNOPSIS
        Returns the safe maximum data-chunk count for a zone based on its Cloudflare plan.
    .DESCRIPTION
        Queries the Cloudflare API for the zone's plan, then maps it to a record limit
        with a 15-record safety buffer for NS/SOA and other overhead:
            Free       200 records  →  185 safe chunks
            Pro       3500 records  → 3400 safe chunks
            Business  3500 records  → 3400 safe chunks
            Enterprise             → 3400 safe chunks (conservative)
    #>
    param([string]$ZoneId)

    $response = Invoke-RestMethod `
        -Uri     "$Script:CF_API/zones/$ZoneId" `
        -Headers (Get-CFHeaders) `
        -Method  Get

    if (-not $response.success) {
        Write-Warning "Could not read zone plan for $ZoneId — assuming free tier."
        return 185
    }

    $planId = $response.result.plan.legacy_id
    switch ($planId) {
        'free'       { return 185  }
        'pro'        { return 3400 }
        'business'   { return 3400 }
        'enterprise' { return 3400 }
        default {
            Write-Warning "Unknown plan '$planId' for zone $ZoneId — assuming free tier (185 chunks)."
            return 185
        }
    }
}


function Split-IntoChunks {
    <#
    .SYNOPSIS
        Splits a string into an array of fixed-length substrings.
    .PARAMETER InputString
        The string to split (typically a Base64-encoded file).
    .PARAMETER ChunkSize
        Maximum number of characters per chunk.
    #>
    param(
        [string]$InputString,
        [int]$ChunkSize = $Script:CHUNK_SIZE
    )

    $chunks = [System.Collections.Generic.List[string]]::new()
    $pos = 0
    while ($pos -lt $InputString.Length) {
        $len = [Math]::Min($ChunkSize, $InputString.Length - $pos)
        $chunks.Add($InputString.Substring($pos, $len))
        $pos += $len
    }
    return $chunks.ToArray()
}

function New-CFTxtRecord {
    <#
    .SYNOPSIS
        Creates a single TXT record in Cloudflare DNS.
    .PARAMETER ZoneId
        The Cloudflare Zone ID (obtained via Get-ZoneId).
    .PARAMETER Name
        The full record name, e.g. "myfile-0.example.com".
    .PARAMETER Content
        The TXT record value (Base64 chunk or JSON metadata string).
    .PARAMETER TTL
        Time-to-live in seconds. 1 = Cloudflare automatic TTL.
    #>
    param(
        [string]$ZoneId,
        [string]$Name,
        [string]$Content,
        [int]$TTL = 1
    )

    $body = @{
        type    = 'TXT'
        name    = $Name
        content = $Content
        ttl     = $TTL
    } | ConvertTo-Json

    $response = Invoke-RestMethod `
        -Uri     "$Script:CF_API/zones/$ZoneId/dns_records" `
        -Headers (Get-CFHeaders) `
        -Method  Post `
        -Body    $body

    if (-not $response.success) {
        throw "Failed to create record '$Name': $($response.errors | ConvertTo-Json)"
    }
    return $response.result
}

function Remove-CFTXTRecordsByPrefix {
    <#
    .SYNOPSIS
        Deletes all TXT records whose names start with a given prefix in a zone.
    .DESCRIPTION
        Used internally to clean up existing chunks before re-uploading a file,
        preventing stale/orphaned chunk records from interfering with extraction.
    .PARAMETER ZoneId
        The Cloudflare Zone ID.
    .PARAMETER Prefix
        The record name prefix (e.g. "myfile" matches "myfile-0", "myfile-meta", etc.).
    .PARAMETER Zone
        The DNS zone name, used to construct the full record name for matching.
    #>
    param(
        [string]$ZoneId,
        [string]$Prefix,
        [string]$Zone
    )

    # Fetch all TXT records in the zone (paginated at 100 per page)
    $page = 1
    $toDelete = [System.Collections.Generic.List[string]]::new()

    do {
        $response = Invoke-RestMethod `
            -Uri     ("$Script:CF_API/zones/$ZoneId/dns_records?type=TXT" + "&per_page=100&page=$page") `
            -Headers (Get-CFHeaders) `
            -Method  Get

        if (-not $response.success) { break }

        foreach ($record in $response.result) {
            # Match records that begin with "<prefix>-" under this zone
            if ($record.name -like "$Prefix-*.$Zone" -or $record.name -like "$Prefix-*") {
                $toDelete.Add($record.id)
            }
        }

        $page++
    } while ($response.result_info.page -lt $response.result_info.total_pages)

    $deleted = 0
    $total   = $toDelete.Count

    if ($total -gt 0) {
        foreach ($id in $toDelete) {
            $deleted++
            Write-Progress `
                -Activity "Removing DNS records: $Prefix.$Zone" `
                -Status   ("Record {0}/{1}" -f $deleted, $total) `
                -PercentComplete ([Math]::Round(($deleted / $total) * 100))

            Invoke-RestMethod `
                -Uri     "$Script:CF_API/zones/$ZoneId/dns_records/$id" `
                -Headers (Get-CFHeaders) `
                -Method  Delete | Out-Null
        }

        Write-Progress -Activity "Removing DNS records: $Prefix.$Zone" -Completed
    }

    Write-Verbose "Removed $total existing record(s) with prefix '$Prefix'."
}

# ──────────────────────────────────────────────────────────────────────────────
# PUBLIC FUNCTIONS
# ──────────────────────────────────────────────────────────────────────────────

function Set-CFCredential {
    <#
    .SYNOPSIS
        Stores your Cloudflare API token for use by other module functions.

    .DESCRIPTION
        Saves the API token in a module-scoped variable for the current PowerShell
        session. The token is NOT persisted to disk by this function — you must
        call Set-CFCredential each session, or add it to your $PROFILE.

        To create an API token in Cloudflare:
          1. Log in to https://dash.cloudflare.com
          2. Go to My Profile → API Tokens → Create Token
          3. Use the "Edit zone DNS" template
          4. Under "Zone Resources", select the specific zone(s) or "All zones"
          5. Click Continue to summary → Create Token
          6. Copy the token — it is only shown once!

    .PARAMETER ApiToken
        Your Cloudflare API Token (starts with a long alphanumeric string).
        Accepts a plain string or a SecureString.

    .EXAMPLE
        Set-CFCredential -ApiToken 'your_token_here'

    .EXAMPLE
        # Prompt securely (token won't echo to terminal)
        $token = Read-Host 'Cloudflare API Token' -AsSecureString
        Set-CFCredential -ApiToken $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ApiToken   # Accepts [string] or [SecureString]
    )

    if ($ApiToken -is [System.Security.SecureString]) {
        # Convert SecureString → plain text for use in HTTP headers
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiToken)
        $Script:CFApiToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } else {
        $Script:CFApiToken = $ApiToken
    }

    Write-Host 'Cloudflare API token stored for this session.' -ForegroundColor Green
}

function Get-CFZone {
    <#
    .SYNOPSIS
        Lists all DNS zones accessible with the configured API token.

    .DESCRIPTION
        Useful to discover zone names before calling Publish-TXTRecord or
        Remove-TXTRecord. Returns zone name, ID, status, and plan.

    .EXAMPLE
        Set-CFCredential -ApiToken 'your_token_here'
        Get-CFZone

    .OUTPUTS
        PSCustomObject[] — Each object has Name, Id, Status, Plan properties.
    #>
    [CmdletBinding()]
    param()

    $page = 1
    $allZones = [System.Collections.Generic.List[object]]::new()

    do {
        $response = Invoke-RestMethod `
            -Uri     ("$Script:CF_API/zones?per_page=50" + "&page=$page") `
            -Headers (Get-CFHeaders) `
            -Method  Get

        if (-not $response.success) {
            throw "Failed to retrieve zones: $($response.errors | ConvertTo-Json)"
        }

        foreach ($z in $response.result) {
            $allZones.Add([PSCustomObject]@{
                Name   = $z.name
                Id     = $z.id
                Status = $z.status
                Plan   = $z.plan.name
            })
        }
        $page++
    } while ($response.result_info.page -lt $response.result_info.total_pages)

    return $allZones
}

function Publish-TXTRecord {
    <#
    .SYNOPSIS
        Encodes a binary file and stores it as DNS TXT records in Cloudflare.

    .DESCRIPTION
        Reads the file at -Path, Base64-encodes its contents, splits the result
        into $Script:CHUNK_SIZE-character chunks, then creates numbered TXT records:

            <Prefix>-meta.<Zone>   → JSON: { filename, chunks, sha256, size }
            <Prefix>-0.<Zone>      → Base64 chunk 0
            <Prefix>-1.<Zone>      → Base64 chunk 1
            ...

        If records with the same prefix already exist, they are deleted first
        (pass -Force to skip the confirmation prompt).

        Use -Resume to continue an interrupted upload. The module will scan
        Cloudflare for the highest chunk already present and skip ahead to the
        next missing one, leaving existing records untouched.

        Progress is shown via Write-Progress. Large files may take several minutes
        due to Cloudflare API rate limits (~1200 requests per 5 minutes on free tier).

    .PARAMETER Path
        Path to the source file (e.g. C:\Videos\clip.mp4).

    .PARAMETER Zone
        The DNS zone to publish records into (e.g. "example.com").
        Must be accessible with the configured API token.

    .PARAMETER Prefix
        The subdomain prefix for record names (e.g. "myvideo").
        Records will be named myvideo-0.example.com, myvideo-1.example.com, etc.
        Allowed characters: letters, numbers, hyphens.

    .PARAMETER TTL
        DNS TTL in seconds for created records. Default 1 (Cloudflare auto).

    .PARAMETER Force
        Skip the confirmation prompt when overwriting existing records.

    .PARAMETER Resume
        Resume an interrupted upload. Verifies all existing chunks against the
        local file, then continues from the first missing or corrupt chunk.
        Skips the cleanup step — valid existing records are left untouched.
        The source file must be identical to the original upload.

    .NOTES
        Rate limiting is handled automatically for the Cloudflare free tier.
        The module targets 3 requests/sec with up to 3 concurrent in-flight
        requests. On a 429 response it reads the Retry-After header and backs
        off with exponential delay, then resumes automatically. No tuning needed.

    .EXAMPLE
        Set-CFCredential -ApiToken 'abc123'
        Publish-TXTRecord -Path 'C:\clip.mp4' -Zone 'example.com' -Prefix 'clip'

    .EXAMPLE
        # Resume after a Ctrl+C or connection drop
        Publish-TXTRecord -Path 'C:\clip.mp4' -Zone 'example.com' -Prefix 'clip' -Resume

    .EXAMPLE
        # Overwrite without prompting
        Publish-TXTRecord -Path 'C:\clip.mp4' -Zone 'example.com' -Prefix 'clip' -Force
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Zone,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9\-]+$')]
        [string]$Prefix,

        [int]$TTL = 1,

        [switch]$Force,

        # When set, verifies existing chunks and resumes from the first missing/corrupt one.
        [switch]$Resume
    )

    # Bring rate-limit constants into local scope for use in task closures
    # (script-scoped variables are not directly visible inside Task::Run lambdas)
    $cfMaxConcurrency = $Script:CF_MAX_CONCURRENCY
    $cfRateLimitRps   = $Script:CF_RATE_LIMIT_RPS
    $cf429BaseWait    = $Script:CF_429_BASE_WAIT
    $cf429MaxWait     = $Script:CF_429_MAX_WAIT
    $cfMaxRetries     = $Script:CF_MAX_RETRIES

    # ── Resolve zone ID ────────────────────────────────────────────────────────
    Write-Verbose "Resolving Zone ID for '$Zone'..."
    $zoneId = Get-ZoneId -Zone $Zone

    # ── Read & encode file ─────────────────────────────────────────────────────
    Write-Host "Reading file: $Path" -ForegroundColor Cyan
    $resolvedFile = (Resolve-Path $Path).Path
    $fileName     = [System.IO.Path]::GetFileName($Path)
    $fileSize     = (Get-Item $resolvedFile).Length

    # ── Compute SHA-256 hash via stream (no full file load) ────────────────────
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashStream = [System.IO.File]::OpenRead($resolvedFile)
    try {
        $hashBytes = $sha256.ComputeHash($hashStream)
    } finally {
        $hashStream.Close()
        $hashStream.Dispose()
    }
    $hashHex = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    # ── Build Base64 chunks directly from file stream ──────────────────────────
    # We read raw bytes in blocks that are a multiple of 3 (so Base64 output has
    # no padding mid-stream), encode each block, then carve DNS-sized chunks from
    # a small rolling buffer. This keeps memory usage to a few MB regardless of
    # file size.
    Write-Host ("File size   : {0:N0} bytes" -f $fileSize) -ForegroundColor Cyan

    $base64Len  = 4 * [Math]::Ceiling($fileSize / 3)   # predicted total Base64 length
    Write-Host ("Base64 size : {0:N0} chars (estimated)" -f $base64Len) -ForegroundColor Cyan

    $totalChunks = [int][Math]::Ceiling($base64Len / $Script:CHUNK_SIZE)
    Write-Host ("Chunks      : {0:N0} TXT records (+ 1 metadata record)" -f $totalChunks) -ForegroundColor Cyan

    # ── Warn about large files ─────────────────────────────────────────────────
    if ($totalChunks -gt 500) {
        Write-Warning ("This file requires {0:N0} DNS records. Publishing may take ~{1:N0} minutes and could hit Cloudflare rate limits." -f $totalChunks, [Math]::Ceiling($totalChunks / 200))
    }

    # ── Resume mode: find highest existing chunk and fast-forward the file stream
    # ── Normal mode: clean up any existing records, then upload fresh
    $resumeFromChunk = 0

    if ($Resume) {
        Write-Host 'Resume mode: verifying existing chunks against local file...' -ForegroundColor Yellow

        # ── Step 1: verify the metadata record matches this file ───────────────
        # We do this first so we fail fast before doing any chunk work if the
        # wrong file was passed in.
        $metaVerified = $false
        try {
            $metaLookup = Invoke-RestMethod `
                -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT&name=$Prefix-meta.$Zone") `
                -Headers (Get-CFHeaders) `
                -Method  Get

            if ($metaLookup.success -and $metaLookup.result.Count -gt 0) {
                $existingMeta = $metaLookup.result[0].content | ConvertFrom-Json
                if ($existingMeta.sha256 -ne $hashHex) {
                    throw ("Resume failed: the metadata record for '$Prefix' has a different SHA-256 hash. " +
                           "The file on disk does not match the file that was originally uploaded. " +
                           "Use Publish-TXTRecord without -Resume to start a fresh upload.")
                }
                $metaVerified = $true
                Write-Host '  ✓ Metadata record verified.' -ForegroundColor Green
            } else {
                Write-Warning "No metadata record found for '$Prefix' — will create one and start from chunk 0."
            }
        } catch [System.Management.Automation.RuntimeException] {
            throw  # re-throw our own descriptive error from above
        } catch {
            Write-Warning "Could not read metadata record — will re-create it: $_"
        }

        # ── Step 2: scan all TXT record names to find the highest chunk index ──
        # This is a single paginated API call — no content is fetched yet.
        # We only need names to establish where the upload boundary is.
        Write-Host '  Scanning DNS for existing chunk records...' -ForegroundColor Yellow
        $highestChunk = -1
        $scanPage     = 1
        do {
            Write-Progress -Activity "Scanning for existing chunks: $Prefix.$Zone" `
                -Status ("Scanning page {0}..." -f $scanPage) -PercentComplete -1
            $scanResp = Invoke-RestMethod `
                -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT&per_page=100&page=$scanPage") `
                -Headers (Get-CFHeaders) -Method Get
            if (-not $scanResp.success) { break }
            foreach ($r in $scanResp.result) {
                if ($r.name -match "^$([regex]::Escape($Prefix))-(\d+)\.$([regex]::Escape($Zone))$") {
                    $idx = [int]$Matches[1]
                    if ($idx -gt $highestChunk) { $highestChunk = $idx }
                }
            }
            $scanPage++
        } while ($scanResp.result_info.page -lt $scanResp.result_info.total_pages)
        Write-Progress -Activity "Scanning for existing chunks: $Prefix.$Zone" -Completed

        $resumeFromChunk = 0
        $verifiedCount   = 0

        if ($highestChunk -lt 0) {
            Write-Host '  No existing chunks found — starting from the beginning.' -ForegroundColor Yellow
        } else {
            Write-Host ("  Highest chunk found: {0}. Verifying boundary window..." -f $highestChunk) -ForegroundColor Yellow

            # ── Step 3: verify only the boundary window ───────────────────────
            # Chunks well below the boundary are trusted — only the last
            # $Script:CF_RESUME_VERIFY_WINDOW chunks need content-checking since
            # those are the only ones that could have been partially written.
            # We decode the relevant slice of the file to get expected values.
            $windowSize  = $Script:CF_RESUME_VERIFY_WINDOW
            $windowStart = [Math]::Max(0, $highestChunk - $windowSize + 1)
            $windowEnd   = $highestChunk   # inclusive
            $windowCount = $windowEnd - $windowStart + 1

            Write-Host ("  Verifying chunks {0}–{1} ({2} chunks)..." -f $windowStart, $windowEnd, $windowCount) -ForegroundColor Yellow

            # Decode only the window slice from the file.
            # Seek to the byte offset of $windowStart, encode forward through $windowEnd.
            $charsToWindowStart = $windowStart * $Script:CHUNK_SIZE
            $bytesToSeek        = [long]([Math]::Floor($charsToWindowStart / 4) * 3)
            $partialChars       = $charsToWindowStart % 4

            $wStream  = [System.IO.File]::OpenRead($resolvedFile)
            $wBuffer  = New-Object byte[] (3 * 1024 * 1024)
            $wChunks  = [System.Collections.Generic.List[string]]::new()
            $wLeftover = ''
            try {
                $wStream.Seek($bytesToSeek, [System.IO.SeekOrigin]::Begin) | Out-Null
                if ($partialChars -gt 0) {
                    $wStream.Seek(-3, [System.IO.SeekOrigin]::Current) | Out-Null
                    $triplet = New-Object byte[] 3
                    $wStream.Read($triplet, 0, 3) | Out-Null
                    $wLeftover = [Convert]::ToBase64String($triplet).Substring($partialChars)
                }
                while (($wRead = $wStream.Read($wBuffer, 0, $wBuffer.Length)) -gt 0) {
                    $wLeftover += [Convert]::ToBase64String($wBuffer, 0, $wRead)
                    while ($wLeftover.Length -ge $Script:CHUNK_SIZE -and $wChunks.Count -lt $windowCount) {
                        $wChunks.Add($wLeftover.Substring(0, $Script:CHUNK_SIZE))
                        $wLeftover = $wLeftover.Substring($Script:CHUNK_SIZE)
                    }
                    if ($wChunks.Count -ge $windowCount) { break }
                }
                if ($wChunks.Count -lt $windowCount -and $wLeftover.Length -gt 0) {
                    $wChunks.Add($wLeftover)
                }
            } finally {
                $wStream.Close(); $wStream.Dispose()
            }

            # Verify each chunk in the window sequentially (window is small, ~10 calls)
            $firstBad = -1
            for ($w = 0; $w -lt $wChunks.Count; $w++) {
                $chunkIdx = $windowStart + $w
                Write-Progress -Activity "Verifying boundary window: $Prefix.$Zone" `
                    -Status ("Chunk {0} ({1}/{2})" -f $chunkIdx, ($w+1), $wChunks.Count) `
                    -PercentComplete ([Math]::Round(($w / $wChunks.Count) * 100))
                try {
                    $vResp = Invoke-RestMethod `
                        -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT&name=$Prefix-$chunkIdx.$Zone") `
                        -Headers (Get-CFHeaders) -Method Get -ErrorAction Stop
                    if (-not $vResp.success -or $vResp.result.Count -eq 0) {
                        Write-Verbose "  Chunk $chunkIdx missing in window."
                        $firstBad = $chunkIdx; break
                    }
                    $dnsVal = $vResp.result[0].content.Trim('"')
                    if ($dnsVal -ne $wChunks[$w]) {
                        Write-Warning "  Chunk $chunkIdx content mismatch in window."
                        $firstBad = $chunkIdx; break
                    }
                    $verifiedCount++
                } catch {
                    Write-Warning "  Chunk $chunkIdx query failed — treating as boundary."
                    $firstBad = $chunkIdx; break
                }
            }
            Write-Progress -Activity "Verifying boundary window: $Prefix.$Zone" -Completed

            if ($firstBad -ge 0) {
                $resumeFromChunk = $firstBad
                Write-Host ("  ✓ Window verified up to chunk {0}. First issue at chunk {1} — resuming from there." -f ($firstBad - 1), $firstBad) -ForegroundColor Green
            } else {
                # Entire window is clean — resume from just after the highest chunk
                $resumeFromChunk = $highestChunk + 1
                Write-Host ("  ✓ Boundary window clean. Resuming from chunk {0} of {1}." -f $resumeFromChunk, $totalChunks) -ForegroundColor Green
            }

            if ($resumeFromChunk -ge $totalChunks) {
                Write-Host ("  ✓ All {0:N0} chunks already present. Nothing to upload!" -f $totalChunks) -ForegroundColor Green
                return
            }
        }

        # Re-create metadata record if it was missing or unreadable
        if (-not $metaVerified) {
            Write-Host '  Re-creating metadata record...' -ForegroundColor Yellow
            $meta = [ordered]@{
                filename = $fileName
                chunks   = $totalChunks
                sha256   = $hashHex
                size     = $fileSize
            } | ConvertTo-Json -Compress
            New-CFTxtRecord -ZoneId $zoneId -Name "$Prefix-meta.$Zone" -Content $meta -TTL $TTL | Out-Null
        }

    } else {
        # Normal (non-resume) upload — confirm then wipe any existing records
        if (-not $Force) {
            $confirm = $PSCmdlet.ShouldProcess(
                "$Prefix-*.$Zone",
                "Delete existing TXT records with this prefix and upload $totalChunks new records"
            )
            if (-not $confirm) { return }
        }

        Write-Host 'Checking for existing records to remove...' -ForegroundColor Yellow
        Remove-CFTXTRecordsByPrefix -ZoneId $zoneId -Prefix $Prefix -Zone $Zone

        # ── Upload metadata record ─────────────────────────────────────────────
        $meta = [ordered]@{
            filename = $fileName
            chunks   = $totalChunks
            sha256   = $hashHex
            size     = $fileSize
        } | ConvertTo-Json -Compress

        Write-Host 'Publishing metadata record...' -ForegroundColor Cyan
        New-CFTxtRecord -ZoneId $zoneId -Name "$Prefix-meta.$Zone" -Content $meta -TTL $TTL | Out-Null
    }

    # ── Pre-encode all chunks from the file into memory ──────────────────────────
    # We fully encode the file into a list of chunk strings before dispatching any
    # API calls. This separates the encoding (sequential, CPU-bound) from the upload
    # (parallel, IO-bound) and means we never have a race between the file stream
    # and concurrent HTTP tasks writing record IDs back to the results collection.
    if ($resumeFromChunk -gt 0) {
        Write-Host ("Pre-encoding chunks {0}–{1} for parallel upload..." -f $resumeFromChunk, ($totalChunks - 1)) -ForegroundColor Cyan
    } else {
        Write-Host ("Pre-encoding {0} chunks for parallel upload..." -f $totalChunks) -ForegroundColor Cyan
    }

    $allChunks   = [System.Collections.Generic.List[string]]::new()
    $encStream   = [System.IO.File]::OpenRead($resolvedFile)
    $encBuffer   = New-Object byte[] (3 * 1024 * 1024)
    $encLeftover = ''

    # Fast-forward the stream if resuming, using the same byte-seek logic as before
    if ($resumeFromChunk -gt 0) {
        $charsToSkip  = $resumeFromChunk * $Script:CHUNK_SIZE
        $bytesToSkip  = [long]([Math]::Floor($charsToSkip / 4) * 3)
        $encStream.Seek($bytesToSkip, [System.IO.SeekOrigin]::Begin) | Out-Null
        $partialChars = $charsToSkip % 4
        if ($partialChars -gt 0) {
            $encStream.Seek(-3, [System.IO.SeekOrigin]::Current) | Out-Null
            $triplet = New-Object byte[] 3
            $encStream.Read($triplet, 0, 3) | Out-Null
            $encLeftover = [Convert]::ToBase64String($triplet).Substring($partialChars)
        }
        Write-Verbose ("Fast-forwarded encoder: skipped {0:N0} bytes, starting at chunk {1}." -f $bytesToSkip, $resumeFromChunk)
    }

    try {
        while (($encRead = $encStream.Read($encBuffer, 0, $encBuffer.Length)) -gt 0) {
            $encLeftover += [Convert]::ToBase64String($encBuffer, 0, $encRead)
            while ($encLeftover.Length -ge $Script:CHUNK_SIZE) {
                $allChunks.Add($encLeftover.Substring(0, $Script:CHUNK_SIZE))
                $encLeftover = $encLeftover.Substring($Script:CHUNK_SIZE)
            }
        }
        if ($encLeftover.Length -gt 0) { $allChunks.Add($encLeftover) }
    } finally {
        $encStream.Close()
        $encStream.Dispose()
    }
    Write-Host ("  {0:N0} chunks ready." -f $allChunks.Count) -ForegroundColor Cyan

    # ── Parallel upload with auto-throttle ───────────────────────────────────
    # Uses a SemaphoreSlim (concurrency cap) + token bucket (rate cap) to stay
    # safely within the Cloudflare free tier limit of 1200 req/5 min (~4 req/sec).
    # Target: 3 req/sec sustained with 3 concurrent in-flight requests.
    # On a 429 Too Many Requests response, the affected task reads the Retry-After
    # header, sleeps that duration, then retries with exponential backoff.
    # This all happens inside the task — the main thread just watches progress.
    if ($resumeFromChunk -gt 0) {
        Write-Host ("Resuming upload from chunk {0} of {1}... (press Ctrl+C to cancel and roll back new chunks only)" -f $resumeFromChunk, $totalChunks) -ForegroundColor Cyan
    } else {
        Write-Host ("Publishing {0} chunks... (press Ctrl+C to cancel and roll back)" -f $allChunks.Count) -ForegroundColor Cyan
    }
    Write-Host  "  (Auto-throttled: 3 req/sec, 3 concurrent, 429-aware backoff)" -ForegroundColor DarkCyan

    $stopwatch      = [System.Diagnostics.Stopwatch]::StartNew()
    $cancelled      = $false

    # RunspacePool: each runspace gets all its variables explicitly injected.
    # Shared state (results, progress, rate limiter) passed as .NET reference objects.
    # Ctrl+C is handled by PowerShell's own pipeline interruption — no CancelKeyPress
    # delegate needed. The finally block detects incomplete jobs and triggers rollback.
    $uploadResults  = [System.Collections.Concurrent.ConcurrentDictionary[int,string]]::new()
    $uploadProgress = [System.Collections.Concurrent.ConcurrentBag[byte]]::new()
    $uJobs          = [System.Collections.Generic.List[hashtable]]::new()

    $uRateState              = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $uRateState['lock']      = [object]::new()
    $uRateState['nextAt']    = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $uRateState['ticksPer']  = [long]([System.Diagnostics.Stopwatch]::Frequency / $cfRateLimitRps)

    $uPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $cfMaxConcurrency)
    $uPool.Open()

    $uWorker = {
        param($idx, $chunkText, $recName, $zId, $ttlVal,
              $cfApi, $cfToken, $uploadResults, $uploadProgress,
              $uRateState, $cfMaxRetries, $cf429BaseWait, $cf429MaxWait)
        try {
            $attempt  = 0
            $waitSecs = $cf429BaseWait
            $done     = $false
            while (-not $done -and $attempt -lt $cfMaxRetries) {
                [System.Threading.Monitor]::Enter($uRateState['lock'])
                try {
                    $now = [System.Diagnostics.Stopwatch]::GetTimestamp()
                    if ($now -lt $uRateState['nextAt']) {
                        $ms = [long](($uRateState['nextAt'] - $now) * 1000 / [System.Diagnostics.Stopwatch]::Frequency)
                        if ($ms -gt 0) { [System.Threading.Thread]::Sleep($ms) }
                    }
                    $uRateState['nextAt'] = [System.Diagnostics.Stopwatch]::GetTimestamp() + $uRateState['ticksPer']
                } finally { [System.Threading.Monitor]::Exit($uRateState['lock']) }

                try {
                    $body = @{ type='TXT'; name=$recName; content=$chunkText; ttl=$ttlVal } | ConvertTo-Json
                    $resp = Invoke-RestMethod -Uri "$cfApi/zones/$zId/dns_records" `
                        -Headers @{ Authorization="Bearer $cfToken"; 'Content-Type'='application/json' } `
                        -Method Post -Body $body -ErrorAction Stop
                    if ($resp.success) { $uploadResults[$idx] = $resp.result.id }
                    else { $uploadResults[$idx] = "ERROR:$($resp.errors | ConvertTo-Json -Compress)" }
                    $done = $true
                } catch {
                    $e = $_.ToString()
                    if ($e -match '429|Too Many Requests') {
                        $attempt++
                        $retryAfter = $waitSecs
                        if ($e -match 'Retry-After:\s*(\d+)') { $retryAfter = [int]$Matches[1] }
                        [System.Threading.Thread]::Sleep($retryAfter * 1000)
                        $waitSecs = [Math]::Min($waitSecs * 2, $cf429MaxWait)
                    } else { $uploadResults[$idx] = "ERROR:$e"; $done = $true }
                }
            }
            if (-not $done) { $uploadResults[$idx] = 'ERROR:max retries exceeded' }
        } finally { $uploadProgress.Add(0) | Out-Null }
    }

    # Intercept Ctrl+C manually so the pipeline stays fully alive throughout —
    # PipelineStoppedException kills Write-Host/Invoke-RestMethod in catch/finally,
    # making drain and rollback invisible. Instead we queue keypresses and check
    # for Ctrl+C ourselves inside the polling loop.
    # Dispatch loop: never queue more than $cfMaxConcurrency jobs at once.
    # We track how many have been dispatched vs completed, and only fire a new
    # job when a slot opens. This means on Ctrl+C there are at most
    # $cfMaxConcurrency in-flight requests to wait for — never a backlog of
    # hundreds of queued-but-not-yet-started jobs.
    [Console]::TreatControlCAsInput = $true
    try {
        $dispatched = 0
        $i          = 0
        while ($i -lt $allChunks.Count -and -not $cancelled) {
            # Poll for Ctrl+C
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'C' -and $key.Modifiers -eq 'Control') { $cancelled = $true }
            }
            if ($cancelled) { break }

            # Wait for a free slot before dispatching the next job
            if (($dispatched - $uploadProgress.Count) -ge $cfMaxConcurrency) {
                Start-Sleep -Milliseconds 100
                continue
            }

            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $uPool
            $null = $ps.AddScript($uWorker)
            $null = $ps.AddParameter('idx',            $i)
            $null = $ps.AddParameter('chunkText',      $allChunks[$i])
            $null = $ps.AddParameter('recName',        "$Prefix-$($resumeFromChunk + $i).$Zone")
            $null = $ps.AddParameter('zId',            $zoneId)
            $null = $ps.AddParameter('ttlVal',         $TTL)
            $null = $ps.AddParameter('cfApi',          $Script:CF_API)
            $null = $ps.AddParameter('cfToken',        $Script:CFApiToken)
            $null = $ps.AddParameter('uploadResults',  $uploadResults)
            $null = $ps.AddParameter('uploadProgress', $uploadProgress)
            $null = $ps.AddParameter('uRateState',     $uRateState)
            $null = $ps.AddParameter('cfMaxRetries',   $cfMaxRetries)
            $null = $ps.AddParameter('cf429BaseWait',  $cf429BaseWait)
            $null = $ps.AddParameter('cf429MaxWait',   $cf429MaxWait)
            $uJobs.Add(@{ PS = $ps; AR = $ps.BeginInvoke() })
            $dispatched++
            $i++

            $done = $uploadProgress.Count
            Write-Progress -Activity "Uploading to DNS: $Prefix.$Zone" `
                -Status ("Uploaded {0}/{1}" -f $done, $allChunks.Count) `
                -PercentComplete ([Math]::Round((($resumeFromChunk + $done) / $totalChunks) * 100))
        }

        # Wait for the last batch of in-flight jobs to finish
        if ($cancelled) {
            Write-Host ''
            Write-Host '  Ctrl+C received — finishing current requests then rolling back...' -ForegroundColor Yellow
        }
        while ($uploadProgress.Count -lt $dispatched) {
            $inFlight = $dispatched - $uploadProgress.Count
            if ($cancelled) {
                Write-Progress -Activity "Cancelling: $Prefix.$Zone" `
                    -Status ("Waiting for {0} in-flight request(s)..." -f $inFlight) `
                    -PercentComplete ([Math]::Round(($uploadProgress.Count / [Math]::Max($dispatched,1)) * 100))
            } else {
                $done = $uploadProgress.Count
                Write-Progress -Activity "Uploading to DNS: $Prefix.$Zone" `
                    -Status ("Uploaded {0}/{1}" -f $done, $allChunks.Count) `
                    -PercentComplete ([Math]::Round((($resumeFromChunk + $done) / $totalChunks) * 100))
            }
            Start-Sleep -Milliseconds 200
        }
        if ($cancelled) { Write-Progress -Activity "Cancelling: $Prefix.$Zone" -Completed }
    } finally {
        [Console]::TreatControlCAsInput = $false
        foreach ($j in $uJobs) { try { $j.PS.Dispose() } catch {} }
        try { $uPool.Close(); $uPool.Dispose() } catch {}
        Write-Progress -Activity "Uploading to DNS: $Prefix.$Zone" -Completed
    }

    # Collect results — any job that has a result ID goes into the rollback list.
    # Jobs that never completed (cancelled before they ran) simply have no entry.
    $uploadedRecordIds = [System.Collections.Generic.List[string]]::new()
    $failedChunks      = [System.Collections.Generic.List[int]]::new()

    for ($i = 0; $i -lt $allChunks.Count; $i++) {
        $res = $null
        if ($uploadResults.TryGetValue($i, [ref]$res)) {
            if ($res -like 'ERROR:*') {
                $failedChunks.Add($resumeFromChunk + $i)
                Write-Warning ("Chunk {0} failed: {1}" -f ($resumeFromChunk + $i), $res.Substring(6))
            } else {
                $uploadedRecordIds.Add($res)
            }
        }
    }

    if ($failedChunks.Count -gt 0 -and -not $cancelled) {
        Write-Warning ("{0} chunk(s) failed. Re-run with -Resume to retry missing chunks." -f $failedChunks.Count)
    }

    $stopwatch.Stop()

    # ── Rollback on cancellation ───────────────────────────────────────────────
    if ($cancelled) {
        Write-Host ''
        Write-Warning ("Upload cancelled after {0} of ~{1} chunks. Rolling back chunks uploaded this session..." -f $uploadedRecordIds.Count, $totalChunks)

        # In resume mode the metadata record already existed — don't delete it during
        # rollback, as the previously uploaded chunks are still valid and intact.
        if (-not $Resume) {
            Write-Host 'Looking up metadata record for rollback...' -ForegroundColor Yellow
            try {
                $metaLookup = Invoke-RestMethod `
                    -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT&name=$Prefix-meta.$Zone") `
                    -Headers (Get-CFHeaders) `
                    -Method  Get
                if ($metaLookup.success -and $metaLookup.result.Count -gt 0) {
                    $uploadedRecordIds.Insert(0, $metaLookup.result[0].id)
                }
            } catch {
                Write-Warning "Could not look up metadata record for rollback (it may need manual removal): $_"
            }
        }

        $totalToDelete  = $uploadedRecordIds.Count
        $deletedCount   = 0

        Write-Host ("Deleting {0} partial record(s)..." -f $totalToDelete) -ForegroundColor Yellow

        foreach ($recordId in $uploadedRecordIds) {
            $deletedCount++
            Write-Progress `
                -Activity "Rolling back upload: $Prefix.$Zone" `
                -Status   ("Removing record {0}/{1}" -f $deletedCount, $totalToDelete) `
                -PercentComplete ([Math]::Round(($deletedCount / [Math]::Max($totalToDelete, 1)) * 100))
            try {
                Invoke-RestMethod `
                    -Uri     "$Script:CF_API/zones/$zoneId/dns_records/$recordId" `
                    -Headers (Get-CFHeaders) `
                    -Method  Delete | Out-Null
            } catch {
                Write-Warning "Failed to delete record ID '$recordId' during rollback: $_"
            }
        }

        Write-Progress -Activity "Rolling back upload: $Prefix.$Zone" -Completed
        Write-Host ''
        Write-Host ("✓ Rollback complete. {0} record(s) from this session removed." -f $deletedCount) -ForegroundColor Green
        if ($Resume) {
            Write-Host  "  Previously uploaded chunks are intact. Re-run with -Resume to continue." -ForegroundColor Green
        } else {
            Write-Host  "  DNS is clean — no partial records remain." -ForegroundColor Green
            Write-Host  "  Re-run with -Resume to pick up where you left off next time." -ForegroundColor Yellow
        }
        return
    }

    Write-Host ''
    Write-Host '✓ Upload complete!' -ForegroundColor Green
    Write-Host ("  Records created : {0:N0} (1 metadata + {1:N0} chunks)" -f ($totalChunks + 1), $totalChunks)
    Write-Host ("  Time elapsed    : {0}" -f $stopwatch.Elapsed.ToString('mm\:ss'))
    Write-Host ("  Metadata record : $Prefix-meta.$Zone")
    Write-Host ("  Extract with    : Get-TXTRecord -Prefix '$Prefix' -Zone '$Zone' -Path 'output.$([System.IO.Path]::GetExtension($fileName).TrimStart('.'))'")
}

function Get-TXTRecord {
    <#
    .SYNOPSIS
        Extracts a file that was previously stored as DNS TXT records.

    .DESCRIPTION
        Uses Resolve-DnsName (built into Windows) to query each TXT record by name,
        reassembles the Base64 chunks, decodes them, verifies the SHA-256 hash, and
        writes the file to -Path.

        NO Cloudflare API credentials are required — this works from any machine
        that can resolve public DNS, as long as the records have propagated.

        Resolution order:
          1. Query <Prefix>-meta.<Zone> to get chunk count, filename, and hash.
          2. Query <Prefix>-0.<Zone> through <Prefix>-N.<Zone> in order.
          3. Concatenate all Base64 chunks → decode → verify hash → write file.

    .PARAMETER Prefix
        The subdomain prefix used when the file was published (e.g. "clip").

    .PARAMETER Zone
        The DNS zone the records live in (e.g. "example.com").

    .PARAMETER Path
        Output file path (e.g. "C:\Output\clip.mp4"). The directory must exist.
        If omitted, the original filename from the metadata record is used in the
        current working directory.

    .PARAMETER DnsServer
        Optional. IP address of a specific DNS resolver to query (e.g. "1.1.1.1").
        Defaults to the system's configured resolver.

    .PARAMETER Force
        Overwrite the output file if it already exists.

    .EXAMPLE
        # Basic extraction — no API key needed!
        Get-TXTRecord -Prefix 'clip' -Zone 'example.com' -Path 'C:\Output\clip.mp4'

    .EXAMPLE
        # Use Cloudflare's public resolver explicitly
        Get-TXTRecord -Prefix 'clip' -Zone 'example.com' -Path '.\clip.mp4' -DnsServer '1.1.1.1'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$Zone,

        [string]$Path,

        [string]$DnsServer,

        [switch]$Force
    )

    # Internal helper: resolve a single TXT record, optionally via a specific server
    function Resolve-TXT {
        param([string]$Name)
        $params = @{ Name = $Name; Type = 'TXT'; ErrorAction = 'Stop' }
        if ($DnsServer) { $params['Server'] = $DnsServer }

        try {
            $result = Resolve-DnsName @params
            # Resolve-DnsName returns Strings as an array per record; join them
            return ($result | Where-Object { $_.Type -eq 'TXT' } | Select-Object -First 1).Strings -join ''
        } catch {
            throw "DNS resolution failed for '$Name': $_"
        }
    }

    # ── Fetch metadata ─────────────────────────────────────────────────────────
    $metaName = "$Prefix-meta.$Zone"
    Write-Host "Querying metadata: $metaName" -ForegroundColor Cyan

    $metaRaw = Resolve-TXT -Name $metaName
    try {
        $meta = $metaRaw | ConvertFrom-Json
    } catch {
        throw "Metadata record '$metaName' could not be parsed as JSON. Raw value: $metaRaw"
    }

    $totalChunks  = [int]$meta.chunks
    $expectedHash = $meta.sha256
    $origFilename = $meta.filename
    $expectedSize = [long]$meta.size

    Write-Host "  Original file : $origFilename" -ForegroundColor Cyan
    Write-Host ("  File size     : {0:N0} bytes" -f $expectedSize) -ForegroundColor Cyan
    Write-Host ("  Chunks        : {0:N0}" -f $totalChunks) -ForegroundColor Cyan

    # ── Determine output path ──────────────────────────────────────────────────
    if (-not $Path) {
        $Path = Join-Path (Get-Location) $origFilename
        Write-Host "  Output path   : $Path (from metadata)" -ForegroundColor Yellow
    }

    if ((Test-Path $Path) -and -not $Force) {
        throw "Output file '$Path' already exists. Use -Force to overwrite."
    }

    # ── Fetch all chunks ───────────────────────────────────────────────────────
    $sb = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $totalChunks; $i++) {
        $chunkName = "$Prefix-$i.$Zone"

        Write-Progress `
            -Activity "Downloading from DNS: $Prefix.$Zone" `
            -Status   ("Chunk {0}/{1}" -f ($i + 1), $totalChunks) `
            -PercentComplete ([Math]::Round(($i / $totalChunks) * 100))

        $chunk = Resolve-TXT -Name $chunkName
        if ([string]::IsNullOrEmpty($chunk)) {
            throw "Chunk $i ('$chunkName') returned empty or null. File may be incomplete in DNS."
        }
        $sb.Append($chunk) | Out-Null
    }

    Write-Progress -Activity "Downloading from DNS: $Prefix.$Zone" -Completed

    # ── Decode Base64 ──────────────────────────────────────────────────────────
    Write-Host 'Decoding Base64...' -ForegroundColor Cyan
    try {
        $fileBytes = [Convert]::FromBase64String($sb.ToString())
    } catch {
        throw "Base64 decode failed. The TXT records may be corrupted or incomplete: $_"
    }

    # ── Verify integrity ───────────────────────────────────────────────────────
    Write-Host 'Verifying SHA-256 hash...' -ForegroundColor Cyan
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($fileBytes)
    $actualHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    if ($actualHash -ne $expectedHash) {
        Write-Warning "Hash mismatch! File may be corrupted."
        Write-Warning "  Expected : $expectedHash"
        Write-Warning "  Actual   : $actualHash"
    } else {
        Write-Host '  ✓ Hash verified.' -ForegroundColor Green
    }

    # ── Write output file ──────────────────────────────────────────────────────
    $resolvedPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if ($resolvedPath) { $targetPath = $resolvedPath.Path } else { $targetPath = $Path }
    $outDir = [System.IO.Path]::GetDirectoryName($targetPath)
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllBytes($Path, $fileBytes)

    Write-Host ''
    Write-Host '✓ Extraction complete!' -ForegroundColor Green
    Write-Host "  Output file : $Path"
    Write-Host ("  Size        : {0:N0} bytes" -f $fileBytes.Length)
}

function Get-TXTRecordBytes {
    <#
    .SYNOPSIS
        Extracts a file stored as DNS TXT records and returns it as a byte array.

    .DESCRIPTION
        Identical to Get-TXTRecord but never writes to disk. Returns the decoded
        byte[] directly to the pipeline, suitable for in-memory use (e.g. loading
        into a MemoryMappedFile or MemoryStream without touching the filesystem).

    .PARAMETER Prefix
        The subdomain prefix used when the file was published.

    .PARAMETER Zone
        The DNS zone the records live in.

    .PARAMETER DnsServer
        Optional. IP address of a specific DNS resolver to query.

    .EXAMPLE
        $bytes = Get-TXTRecordBytes -Prefix 'doom' -Zone 'example.com'
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$Zone,

        [string]$DnsServer
    )

    function Resolve-TXT {
        param([string]$Name)
        $params = @{ Name = $Name; Type = 'TXT'; ErrorAction = 'Stop' }
        if ($DnsServer) { $params['Server'] = $DnsServer }
        try {
            $result = Resolve-DnsName @params
            return ($result | Where-Object { $_.Type -eq 'TXT' } | Select-Object -First 1).Strings -join ''
        } catch {
            throw "DNS resolution failed for '$Name': $_"
        }
    }

    # ── Fetch metadata ─────────────────────────────────────────────────────────
    $metaName = "$Prefix-meta.$Zone"
    Write-Host "Querying metadata: $metaName" -ForegroundColor Cyan

    $metaRaw = Resolve-TXT -Name $metaName
    try {
        $meta = $metaRaw | ConvertFrom-Json
    } catch {
        throw "Metadata record '$metaName' could not be parsed as JSON. Raw value: $metaRaw"
    }

    $totalChunks  = [int]$meta.chunks
    $expectedHash = $meta.sha256
    $origFilename = $meta.filename
    $expectedSize = [long]$meta.size

    Write-Host "  Original file : $origFilename" -ForegroundColor Cyan
    Write-Host ("  File size     : {0:N0} bytes" -f $expectedSize) -ForegroundColor Cyan
    Write-Host ("  Chunks        : {0:N0}" -f $totalChunks) -ForegroundColor Cyan

    # ── Fetch all chunks ───────────────────────────────────────────────────────
    $sb = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $totalChunks; $i++) {
        $chunkName = "$Prefix-$i.$Zone"

        Write-Progress `
            -Activity "Downloading from DNS: $Prefix.$Zone" `
            -Status   ("Chunk {0}/{1}" -f ($i + 1), $totalChunks) `
            -PercentComplete ([Math]::Round(($i / $totalChunks) * 100))

        $chunk = Resolve-TXT -Name $chunkName
        if ([string]::IsNullOrEmpty($chunk)) {
            throw "Chunk $i ('$chunkName') returned empty or null. File may be incomplete in DNS."
        }
        $sb.Append($chunk) | Out-Null
    }

    Write-Progress -Activity "Downloading from DNS: $Prefix.$Zone" -Completed

    # ── Decode Base64 ──────────────────────────────────────────────────────────
    Write-Host 'Decoding Base64...' -ForegroundColor Cyan
    try {
        $fileBytes = [Convert]::FromBase64String($sb.ToString())
    } catch {
        throw "Base64 decode failed. The TXT records may be corrupted or incomplete: $_"
    }

    # ── Verify integrity ───────────────────────────────────────────────────────
    Write-Host 'Verifying SHA-256 hash...' -ForegroundColor Cyan
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($fileBytes)
    $actualHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    if ($actualHash -ne $expectedHash) {
        Write-Warning "Hash mismatch! File may be corrupted."
        Write-Warning "  Expected : $expectedHash"
        Write-Warning "  Actual   : $actualHash"
    } else {
        Write-Host '  ✓ Hash verified.' -ForegroundColor Green
    }

    Write-Host ("✓ {0:N0} bytes loaded into memory." -f $fileBytes.Length) -ForegroundColor Green

    # Return as a single array (comma prefix prevents PS from unrolling it)
    return ,$fileBytes
}

# ──────────────────────────────────────────────────────────────────────────────
# STRIPE FUNCTIONS  (multi-zone distribution for the 1000-record-per-zone limit)
# ──────────────────────────────────────────────────────────────────────────────

function Publish-TXTStripe {
    <#
    .SYNOPSIS
        Encodes a binary file and distributes it across multiple DNS zones.

    .DESCRIPTION
        Identical to Publish-TXTRecord except the chunks are striped across the
        supplied list of zones in sequential order: zone[0] receives chunks
        0..(ChunksPerZone-1), zone[1] receives the next ChunksPerZone chunks, etc.

        A single stripe-metadata record is written to zone[0]:
            <Prefix>-stripe-meta.<Zones[0]>

        Data chunks use global indices so each record name is unique and stable:
            <Prefix>-<globalIndex>.<zone>

        Example layout (ChunksPerZone = 999):
            doom-stripe-meta.zone0.com  → JSON metadata incl. zones list
            doom-0.zone0.com  …  doom-998.zone0.com
            doom-999.zone1.com  …  doom-1997.zone1.com
            ...

        Extraction only requires the prefix and the primary zone (zone[0]) — the
        zones list is read from the stripe-meta record.

    .PARAMETER Path
        Path to the source file.

    .PARAMETER Zones
        Ordered array of DNS zone names to stripe across. At least 2 required.
        Each zone must be accessible with the configured API token.

    .PARAMETER Prefix
        Subdomain prefix for all record names. Letters, numbers, hyphens only.

    .PARAMETER ChunksPerZone
        Maximum data chunks per zone. Default 999 (leaves 1 slot for meta).

    .PARAMETER TTL
        DNS TTL in seconds. Default 1 (Cloudflare auto).

    .PARAMETER Force
        Skip confirmation prompt when overwriting existing records.

    .PARAMETER Resume
        Resume an interrupted upload. Reads stripe-meta to determine the zones
        list, scans each zone for existing chunks, and resumes from the first
        missing or corrupt chunk. Source file must be identical to the original.

    .EXAMPLE
        Publish-TXTStripe -Path 'DOOM1.WAD' -Zones @('z0.com','z1.com','z2.com') -Prefix 'doom'

    .EXAMPLE
        Publish-TXTStripe -Path 'DOOM1.WAD' -Zones @('z0.com','z1.com','z2.com') -Prefix 'doom' -Resume
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateCount(1, 100)]
        [string[]]$Zones,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9\-]+$')]
        [string]$Prefix,

        [int]$ChunksPerZone = 0,   # 0 = auto-detect from zone plan

        [int]$TTL = 1,

        [switch]$Force,

        [switch]$Resume,

        # GZip-compress the file before encoding. Significantly reduces chunk count
        # for compressible data (WAD files, DLLs). Decompression is automatic on retrieval.
        [switch]$Compress
    )

    $cfMaxConcurrency = $Script:CF_MAX_CONCURRENCY
    $cfRateLimitRps   = $Script:CF_RATE_LIMIT_RPS
    $cf429BaseWait    = $Script:CF_429_BASE_WAIT
    $cf429MaxWait     = $Script:CF_429_MAX_WAIT
    $cfMaxRetries     = $Script:CF_MAX_RETRIES

    $primaryZone      = $Zones[0]
    $stripeMetaName   = "$Prefix-stripe-meta"

    # ── Read & hash file ───────────────────────────────────────────────────────
    Write-Host "Reading file: $Path" -ForegroundColor Cyan
    $resolvedFile = (Resolve-Path $Path).Path
    $fileName     = [System.IO.Path]::GetFileName($Path)
    $fileSize     = (Get-Item $resolvedFile).Length

    # Hash is always computed over the ORIGINAL bytes so retrieval can verify integrity
    $sha256     = [System.Security.Cryptography.SHA256]::Create()
    $hashStream = [System.IO.File]::OpenRead($resolvedFile)
    try   { $hashBytes = $sha256.ComputeHash($hashStream) }
    finally { $hashStream.Close(); $hashStream.Dispose() }
    $hashHex = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    # ── Optional GZip compression ──────────────────────────────────────────────
    # When -Compress is set, we GZip the raw bytes before base64-encoding.
    # The stripe-meta records compressed=true so retrieval knows to decompress.
    # Compression is done in memory; the result replaces the file stream for encoding.
    $encodeBytes  = $null   # set below if compressing; $null means stream from file
    $encodeSize   = $fileSize

    if ($Compress) {
        Write-Host 'Compressing...' -ForegroundColor Cyan
        $rawBytes   = [System.IO.File]::ReadAllBytes($resolvedFile)
        $cmpStream  = [System.IO.MemoryStream]::new()
        $gzip       = [System.IO.Compression.GZipStream]::new($cmpStream, [System.IO.Compression.CompressionLevel]::Optimal)
        $gzip.Write($rawBytes, 0, $rawBytes.Length)
        $gzip.Close()
        $encodeBytes = $cmpStream.ToArray()
        $encodeSize  = $encodeBytes.Length
        $ratio = [Math]::Round((1 - $encodeSize / $fileSize) * 100, 1)
        Write-Host ("  {0:N0} bytes → {1:N0} bytes ({2}% reduction)" -f $fileSize, $encodeSize, $ratio) -ForegroundColor Cyan
    }

    # ── Compute chunk counts ───────────────────────────────────────────────────
    $base64Len   = 4 * [Math]::Ceiling($encodeSize / 3)
    $totalChunks = [int][Math]::Ceiling($base64Len / $Script:CHUNK_SIZE)
    Write-Host ("File size   : {0:N0} bytes{1}" -f $fileSize, $(if ($Compress) { " (compressed: $($encodeSize.ToString('N0')) bytes)" } else { '' })) -ForegroundColor Cyan
    Write-Host ("Total chunks: {0:N0}" -f $totalChunks) -ForegroundColor Cyan

    # ── Resolve zone IDs and detect per-zone capacity ────────────────────────
    # We resolve zones lazily: stop as soon as cumulative capacity >= totalChunks.
    Write-Host 'Resolving zone IDs and checking plan limits...' -ForegroundColor Cyan
    $zoneIds       = @{}
    $zoneCapacities = [System.Collections.Generic.List[int]]::new()
    $zoneStarts     = [System.Collections.Generic.List[int]]::new()   # cumulative chunk starts
    $activeZones    = [System.Collections.Generic.List[string]]::new()
    $cumCap         = 0

    foreach ($z in $Zones) {
        $zId = Get-ZoneId -Zone $z
        $zoneIds[$z] = $zId

        if ($ChunksPerZone -gt 0) {
            $cap = $ChunksPerZone   # manual override: uniform capacity
        } else {
            Write-Host "  $z" -ForegroundColor DarkCyan
            $cap = Get-ZoneSafeCapacity -ZoneId $zId
            Write-Host ("    Plan capacity: {0} safe chunks/zone" -f $cap) -ForegroundColor DarkGray
        }

        $zoneStarts.Add($cumCap)
        $zoneCapacities.Add($cap)
        $activeZones.Add($z)
        $cumCap += $cap

        if ($cumCap -ge $totalChunks) { break }
    }

    if ($cumCap -lt $totalChunks) {
        throw ("File requires {0} chunks but {1} zone(s) provide only {2} chunk slots. " +
               "Add more zones.") -f $totalChunks, $activeZones.Count, $cumCap
    }

    $activeZones    = $activeZones.ToArray()
    $zoneCapacities = $zoneCapacities.ToArray()
    $zoneStarts     = $zoneStarts.ToArray()
    $zonesNeeded    = $activeZones.Count
    $primaryZoneId  = $zoneIds[$primaryZone]

    Write-Host ("Zones needed: {0} of {1} provided" -f $zonesNeeded, $Zones.Count) -ForegroundColor Cyan

    # ── Helper: map global chunk index → zone name ────────────────────────────
    function Get-ChunkZone { param([int]$idx)
        for ($j = $zoneStarts.Count - 1; $j -ge 0; $j--) {
            if ($idx -ge $zoneStarts[$j]) { return $activeZones[$j] }
        }
        return $activeZones[0]
    }

    # ── Resume or fresh start ──────────────────────────────────────────────────
    $resumeFromChunk = 0

    if ($Resume) {
        Write-Host 'Resume mode: reading stripe-meta...' -ForegroundColor Yellow

        # Verify stripe-meta exists and matches this file
        $metaVerified = $false
        try {
            $metaLookup = Invoke-RestMethod `
                -Uri     ("$Script:CF_API/zones/$primaryZoneId/dns_records?type=TXT&name=$stripeMetaName.$primaryZone") `
                -Headers (Get-CFHeaders) -Method Get
            if ($metaLookup.success -and $metaLookup.result.Count -gt 0) {
                $existingMeta = $metaLookup.result[0].content | ConvertFrom-Json
                if ($existingMeta.sha256 -ne $hashHex) {
                    throw "Resume failed: stripe-meta SHA-256 does not match local file. Use -Force to start fresh."
                }
                $metaVerified = $true
                Write-Host '  ✓ Stripe-meta verified.' -ForegroundColor Green
            } else {
                Write-Warning "No stripe-meta found — will create one and start from chunk 0."
            }
        } catch [System.Management.Automation.RuntimeException] { throw }
        catch { Write-Warning "Could not read stripe-meta: $_" }

        # Scan every active zone for the highest chunk index present
        $highestChunk = -1
        foreach ($z in $activeZones) {
            $zId   = $zoneIds[$z]
            $j     = [Array]::IndexOf($activeZones, $z)
            $zMin  = $zoneStarts[$j]
            $zMax  = [Math]::Min($zMin + $zoneCapacities[$j] - 1, $totalChunks - 1)
            $page  = 1
            Write-Host ("  Scanning {0} for chunks {1}–{2}..." -f $z, $zMin, $zMax) -ForegroundColor Yellow
            do {
                $scanResp = Invoke-RestMethod `
                    -Uri     ("$Script:CF_API/zones/$zId/dns_records?type=TXT&per_page=100&page=$page") `
                    -Headers (Get-CFHeaders) -Method Get
                if (-not $scanResp.success) { break }
                foreach ($r in $scanResp.result) {
                    if ($r.name -match "^$([regex]::Escape($Prefix))-(\d+)\.$([regex]::Escape($z))$") {
                        $idx = [int]$Matches[1]
                        if ($idx -gt $highestChunk) { $highestChunk = $idx }
                    }
                }
                $page++
            } while ($scanResp.result_info.page -lt $scanResp.result_info.total_pages)
        }

        if ($highestChunk -lt 0) {
            Write-Host '  No existing chunks found — starting from chunk 0.' -ForegroundColor Yellow
        } else {
            # Verify boundary window
            $windowSize  = $Script:CF_RESUME_VERIFY_WINDOW
            $windowStart = [Math]::Max(0, $highestChunk - $windowSize + 1)
            $windowEnd   = $highestChunk
            Write-Host ("  Highest chunk: {0}. Verifying boundary window {1}–{2}..." -f $highestChunk, $windowStart, $windowEnd) -ForegroundColor Yellow

            # Decode window chunks from file for comparison
            $charsToWindowStart = $windowStart * $Script:CHUNK_SIZE
            $bytesToSeek        = [long]([Math]::Floor($charsToWindowStart / 4) * 3)
            $partialChars       = $charsToWindowStart % 4
            $windowCount        = $windowEnd - $windowStart + 1

            $wStream   = [System.IO.File]::OpenRead($resolvedFile)
            $wBuffer   = New-Object byte[] (3 * 1024 * 1024)
            $wChunks   = [System.Collections.Generic.List[string]]::new()
            $wLeftover = ''
            try {
                $wStream.Seek($bytesToSeek, [System.IO.SeekOrigin]::Begin) | Out-Null
                if ($partialChars -gt 0) {
                    $wStream.Seek(-3, [System.IO.SeekOrigin]::Current) | Out-Null
                    $triplet = New-Object byte[] 3
                    $wStream.Read($triplet, 0, 3) | Out-Null
                    $wLeftover = [Convert]::ToBase64String($triplet).Substring($partialChars)
                }
                while (($wRead = $wStream.Read($wBuffer, 0, $wBuffer.Length)) -gt 0) {
                    $wLeftover += [Convert]::ToBase64String($wBuffer, 0, $wRead)
                    while ($wLeftover.Length -ge $Script:CHUNK_SIZE -and $wChunks.Count -lt $windowCount) {
                        $wChunks.Add($wLeftover.Substring(0, $Script:CHUNK_SIZE))
                        $wLeftover = $wLeftover.Substring($Script:CHUNK_SIZE)
                    }
                    if ($wChunks.Count -ge $windowCount) { break }
                }
                if ($wChunks.Count -lt $windowCount -and $wLeftover.Length -gt 0) { $wChunks.Add($wLeftover) }
            } finally { $wStream.Close(); $wStream.Dispose() }

            $firstBad = -1
            for ($w = 0; $w -lt $wChunks.Count; $w++) {
                $gIdx    = $windowStart + $w
                $wZone   = Get-ChunkZone $gIdx
                $wZoneId = $zoneIds[$wZone]
                try {
                    $vResp = Invoke-RestMethod `
                        -Uri     ("$Script:CF_API/zones/$wZoneId/dns_records?type=TXT&name=$Prefix-$gIdx.$wZone") `
                        -Headers (Get-CFHeaders) -Method Get -ErrorAction Stop
                    if (-not $vResp.success -or $vResp.result.Count -eq 0) { $firstBad = $gIdx; break }
                    if ($vResp.result[0].content.Trim('"') -ne $wChunks[$w]) {
                        Write-Warning "  Chunk $gIdx content mismatch."
                        $firstBad = $gIdx; break
                    }
                } catch { $firstBad = $gIdx; break }
            }

            if ($firstBad -ge 0) {
                $resumeFromChunk = $firstBad
                Write-Host ("  Resuming from chunk {0}." -f $resumeFromChunk) -ForegroundColor Green
            } else {
                $resumeFromChunk = $highestChunk + 1
                Write-Host ("  Boundary clean. Resuming from chunk {0} of {1}." -f $resumeFromChunk, $totalChunks) -ForegroundColor Green
            }

            if ($resumeFromChunk -ge $totalChunks) {
                Write-Host ("  ✓ All {0:N0} chunks already present. Nothing to upload!" -f $totalChunks) -ForegroundColor Green
                return
            }
        }

        if (-not $metaVerified) {
            $metaObj = [ordered]@{
                filename        = $fileName; size = $fileSize; sha256 = $hashHex
                chunks          = $totalChunks; zones = $activeZones
                zone_capacities = $zoneCapacities; chunks_per_zone = $zoneCapacities[0]
                compressed      = $Compress.IsPresent
            }
            New-CFTxtRecord -ZoneId $primaryZoneId -Name "$stripeMetaName.$primaryZone" `
                -Content ($metaObj | ConvertTo-Json -Compress) -TTL $TTL | Out-Null
        }

    } else {
        # Fresh upload — confirm and clean all zones
        if (-not $Force) {
            $confirm = $PSCmdlet.ShouldProcess(
                "$Prefix-* across $($activeZones -join ', ')",
                "Delete existing records and upload $totalChunks chunks across $zonesNeeded zone(s)"
            )
            if (-not $confirm) { return }
        }

        Write-Host 'Cleaning existing records from all zones...' -ForegroundColor Yellow
        foreach ($z in $activeZones) {
            Remove-CFTXTRecordsByPrefix -ZoneId $zoneIds[$z] -Prefix $Prefix -Zone $z
        }
        # Also clean stripe-meta specifically (it won't match the "-*" prefix pattern if zone differs)
        try {
            $smLookup = Invoke-RestMethod `
                -Uri     ("$Script:CF_API/zones/$primaryZoneId/dns_records?type=TXT&name=$stripeMetaName.$primaryZone") `
                -Headers (Get-CFHeaders) -Method Get
            if ($smLookup.success -and $smLookup.result.Count -gt 0) {
                Invoke-RestMethod -Uri "$Script:CF_API/zones/$primaryZoneId/dns_records/$($smLookup.result[0].id)" `
                    -Headers (Get-CFHeaders) -Method Delete | Out-Null
            }
        } catch {}

        # Write stripe-meta
        $metaObj = [ordered]@{
            filename        = $fileName; size = $fileSize; sha256 = $hashHex
            chunks          = $totalChunks; zones = $activeZones
            zone_capacities = $zoneCapacities; chunks_per_zone = $zoneCapacities[0]
            compressed      = $Compress.IsPresent
        }
        Write-Host 'Publishing stripe-meta record...' -ForegroundColor Cyan
        New-CFTxtRecord -ZoneId $primaryZoneId -Name "$stripeMetaName.$primaryZone" `
            -Content ($metaObj | ConvertTo-Json -Compress) -TTL $TTL | Out-Null
    }

    # ── Pre-encode chunks from resume point ────────────────────────────────────
    Write-Host ("Pre-encoding chunks {0}–{1}..." -f $resumeFromChunk, ($totalChunks - 1)) -ForegroundColor Cyan

    $allChunks   = [System.Collections.Generic.List[string]]::new()
    $encBuffer   = New-Object byte[] (3 * 1024 * 1024)
    $encLeftover = ''

    # Use compressed bytes (already in memory) or open the file stream
    if ($encodeBytes -ne $null) {
        $encStream = [System.IO.MemoryStream]::new($encodeBytes, $false)
    } else {
        $encStream = [System.IO.File]::OpenRead($resolvedFile)
    }

    if ($resumeFromChunk -gt 0) {
        $charsToSkip  = $resumeFromChunk * $Script:CHUNK_SIZE
        $bytesToSkip  = [long]([Math]::Floor($charsToSkip / 4) * 3)
        $encStream.Seek($bytesToSkip, [System.IO.SeekOrigin]::Begin) | Out-Null
        $partialChars = $charsToSkip % 4
        if ($partialChars -gt 0) {
            $encStream.Seek(-3, [System.IO.SeekOrigin]::Current) | Out-Null
            $triplet = New-Object byte[] 3
            $encStream.Read($triplet, 0, 3) | Out-Null
            $encLeftover = [Convert]::ToBase64String($triplet).Substring($partialChars)
        }
    }

    try {
        while (($encRead = $encStream.Read($encBuffer, 0, $encBuffer.Length)) -gt 0) {
            $encLeftover += [Convert]::ToBase64String($encBuffer, 0, $encRead)
            while ($encLeftover.Length -ge $Script:CHUNK_SIZE) {
                $allChunks.Add($encLeftover.Substring(0, $Script:CHUNK_SIZE))
                $encLeftover = $encLeftover.Substring($Script:CHUNK_SIZE)
            }
        }
        if ($encLeftover.Length -gt 0) { $allChunks.Add($encLeftover) }
    } finally { $encStream.Close(); $encStream.Dispose() }

    Write-Host ("  {0:N0} chunks ready." -f $allChunks.Count) -ForegroundColor Cyan

    # ── Upload zone by zone, parallel within each zone ────────────────────────
    $uWorker = {
        param($idx, $chunkText, $recName, $zId, $ttlVal,
              $cfApi, $cfToken, $uploadResults, $uploadProgress,
              $uRateState, $cfMaxRetries, $cf429BaseWait, $cf429MaxWait)
        try {
            $attempt  = 0
            $waitSecs = $cf429BaseWait
            $done     = $false
            while (-not $done -and $attempt -lt $cfMaxRetries) {
                [System.Threading.Monitor]::Enter($uRateState['lock'])
                try {
                    $now = [System.Diagnostics.Stopwatch]::GetTimestamp()
                    if ($now -lt $uRateState['nextAt']) {
                        $ms = [long](($uRateState['nextAt'] - $now) * 1000 / [System.Diagnostics.Stopwatch]::Frequency)
                        if ($ms -gt 0) { [System.Threading.Thread]::Sleep($ms) }
                    }
                    $uRateState['nextAt'] = [System.Diagnostics.Stopwatch]::GetTimestamp() + $uRateState['ticksPer']
                } finally { [System.Threading.Monitor]::Exit($uRateState['lock']) }

                try {
                    $body = @{ type='TXT'; name=$recName; content=$chunkText; ttl=$ttlVal } | ConvertTo-Json
                    $resp = Invoke-RestMethod -Uri "$cfApi/zones/$zId/dns_records" `
                        -Headers @{ Authorization="Bearer $cfToken"; 'Content-Type'='application/json' } `
                        -Method Post -Body $body -ErrorAction Stop
                    if ($resp.success) { $uploadResults[$idx] = $resp.result.id }
                    else { $uploadResults[$idx] = "ERROR:$($resp.errors | ConvertTo-Json -Compress)" }
                    $done = $true
                } catch {
                    $e = $_.ToString()
                    if ($e -match '429|Too Many Requests') {
                        $attempt++
                        $retryAfter = $waitSecs
                        if ($e -match 'Retry-After:\s*(\d+)') { $retryAfter = [int]$Matches[1] }
                        [System.Threading.Thread]::Sleep($retryAfter * 1000)
                        $waitSecs = [Math]::Min($waitSecs * 2, $cf429MaxWait)
                    } else { $uploadResults[$idx] = "ERROR:$e"; $done = $true }
                }
            }
            if (-not $done) { $uploadResults[$idx] = 'ERROR:max retries exceeded' }
        } finally { $uploadProgress.Add(0) | Out-Null }
    }

    $stopwatch         = [System.Diagnostics.Stopwatch]::StartNew()
    $cancelled         = $false
    # All record IDs created this session, keyed by zone for targeted rollback
    $sessionRecordIds  = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Collections.Generic.List[string]]]::new()
    foreach ($z in $activeZones) { $sessionRecordIds[$z] = [System.Collections.Generic.List[string]]::new() }

    $uRateState             = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $uRateState['lock']     = [object]::new()
    $uRateState['nextAt']   = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $uRateState['ticksPer'] = [long]([System.Diagnostics.Stopwatch]::Frequency / $cfRateLimitRps)

    [Console]::TreatControlCAsInput = $true
    try {
        $globalUploaded = $resumeFromChunk   # tracks global progress for progress bar

        for ($zIdx = 0; $zIdx -lt $activeZones.Count -and -not $cancelled; $zIdx++) {
            $zone       = $activeZones[$zIdx]
            $zoneId     = $zoneIds[$zone]
            $zGlobalMin = $zoneStarts[$zIdx]
            $zGlobalMax = [Math]::Min($zGlobalMin + $zoneCapacities[$zIdx] - 1, $totalChunks - 1)

            # Determine which allChunks[] slice belongs to this zone
            $zLocalStart = $zGlobalMin - $resumeFromChunk
            $zLocalEnd   = $zGlobalMax - $resumeFromChunk

            if ($zLocalStart -ge $allChunks.Count) { break }   # fully before resume point — skip
            if ($zLocalStart -lt 0) { $zLocalStart = 0 }       # partially before resume point
            $zLocalEnd = [Math]::Min($zLocalEnd, $allChunks.Count - 1)

            $zChunkCount = $zLocalEnd - $zLocalStart + 1
            Write-Host ("Zone {0}/{1}: {2}  (chunks {3}–{4})" -f ($zIdx+1), $activeZones.Count, $zone, ($zGlobalMin + ($zLocalStart - ($zGlobalMin - $resumeFromChunk))), $zGlobalMax) -ForegroundColor Cyan

            $uploadResults  = [System.Collections.Concurrent.ConcurrentDictionary[int,string]]::new()
            $uploadProgress = [System.Collections.Concurrent.ConcurrentBag[byte]]::new()
            $uJobs          = [System.Collections.Generic.List[hashtable]]::new()

            $uPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $cfMaxConcurrency)
            $uPool.Open()

            try {
                $dispatched = 0
                $li         = $zLocalStart

                while ($li -le $zLocalEnd -and -not $cancelled) {
                    while ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true)
                        if ($key.Key -eq 'C' -and $key.Modifiers -eq 'Control') { $cancelled = $true }
                    }
                    if ($cancelled) { break }

                    if (($dispatched - $uploadProgress.Count) -ge $cfMaxConcurrency) {
                        Start-Sleep -Milliseconds 100; continue
                    }

                    $globalIdx = $resumeFromChunk + $li
                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.RunspacePool = $uPool
                    $null = $ps.AddScript($uWorker)
                    $null = $ps.AddParameter('idx',            $li)
                    $null = $ps.AddParameter('chunkText',      $allChunks[$li])
                    $null = $ps.AddParameter('recName',        "$Prefix-$globalIdx.$zone")
                    $null = $ps.AddParameter('zId',            $zoneId)
                    $null = $ps.AddParameter('ttlVal',         $TTL)
                    $null = $ps.AddParameter('cfApi',          $Script:CF_API)
                    $null = $ps.AddParameter('cfToken',        $Script:CFApiToken)
                    $null = $ps.AddParameter('uploadResults',  $uploadResults)
                    $null = $ps.AddParameter('uploadProgress', $uploadProgress)
                    $null = $ps.AddParameter('uRateState',     $uRateState)
                    $null = $ps.AddParameter('cfMaxRetries',   $cfMaxRetries)
                    $null = $ps.AddParameter('cf429BaseWait',  $cf429BaseWait)
                    $null = $ps.AddParameter('cf429MaxWait',   $cf429MaxWait)
                    $uJobs.Add(@{ PS = $ps; AR = $ps.BeginInvoke() })
                    $dispatched++
                    $li++

                    $done = $globalUploaded + $uploadProgress.Count
                    Write-Progress -Activity "Uploading to DNS (zone $($zIdx+1)/$($activeZones.Count): $zone)" `
                        -Status ("Chunk {0}/{1}" -f ($globalUploaded + $uploadProgress.Count), $totalChunks) `
                        -PercentComplete ([Math]::Round((($globalUploaded + $uploadProgress.Count) / $totalChunks) * 100))
                }

                if ($cancelled) { Write-Host '' ; Write-Host '  Ctrl+C — draining in-flight requests...' -ForegroundColor Yellow }

                while ($uploadProgress.Count -lt $dispatched) {
                    Start-Sleep -Milliseconds 200
                    Write-Progress -Activity "Uploading to DNS (zone $($zIdx+1)/$($activeZones.Count): $zone)" `
                        -Status ("Chunk {0}/{1}" -f ($globalUploaded + $uploadProgress.Count), $totalChunks) `
                        -PercentComplete ([Math]::Round((($globalUploaded + $uploadProgress.Count) / $totalChunks) * 100))
                }
            } finally {
                foreach ($j in $uJobs) { try { $j.PS.Dispose() } catch {} }
                try { $uPool.Close(); $uPool.Dispose() } catch {}
                Write-Progress -Activity "Uploading to DNS (zone $($zIdx+1)/$($activeZones.Count): $zone)" -Completed
            }

            # Collect record IDs for rollback and report failures
            for ($li2 = $zLocalStart; $li2 -le $zLocalEnd; $li2++) {
                $res = $null
                if ($uploadResults.TryGetValue($li2, [ref]$res)) {
                    if ($res -like 'ERROR:*') {
                        Write-Warning ("Chunk {0} failed: {1}" -f ($resumeFromChunk + $li2), $res.Substring(6))
                    } else {
                        $sessionRecordIds[$zone].Add($res)
                    }
                }
            }

            $globalUploaded += $zChunkCount
        }
    } finally {
        [Console]::TreatControlCAsInput = $false
    }

    $stopwatch.Stop()

    # ── Rollback on cancellation ───────────────────────────────────────────────
    if ($cancelled) {
        Write-Host ''
        Write-Warning 'Upload cancelled — rolling back records created this session...'

        foreach ($z in $activeZones) {
            $zId  = $zoneIds[$z]
            $ids  = $sessionRecordIds[$z]
            if ($ids.Count -eq 0) { continue }
            Write-Host ("  Deleting {0} record(s) from {1}..." -f $ids.Count, $z) -ForegroundColor Yellow
            foreach ($id in $ids) {
                try {
                    Invoke-RestMethod -Uri "$Script:CF_API/zones/$zId/dns_records/$id" `
                        -Headers (Get-CFHeaders) -Method Delete | Out-Null
                } catch { Write-Warning "  Failed to delete record $id from $z : $_" }
            }
        }

        if (-not $Resume) {
            # Delete stripe-meta too
            try {
                $smLookup = Invoke-RestMethod `
                    -Uri     ("$Script:CF_API/zones/$primaryZoneId/dns_records?type=TXT&name=$stripeMetaName.$primaryZone") `
                    -Headers (Get-CFHeaders) -Method Get
                if ($smLookup.success -and $smLookup.result.Count -gt 0) {
                    Invoke-RestMethod -Uri "$Script:CF_API/zones/$primaryZoneId/dns_records/$($smLookup.result[0].id)" `
                        -Headers (Get-CFHeaders) -Method Delete | Out-Null
                }
            } catch {}
        }

        Write-Host '✓ Rollback complete. Re-run with -Resume to continue.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host '✓ Stripe upload complete!' -ForegroundColor Green
    Write-Host ("  Total records : {0:N0} (1 stripe-meta + {1:N0} chunks across {2} zone(s))" -f ($totalChunks + 1), $totalChunks, $activeZones.Count)
    Write-Host ("  Time elapsed  : {0}" -f $stopwatch.Elapsed.ToString('hh\:mm\:ss'))
    Write-Host ("  Extract with  : Get-TXTStripeBytes -Prefix '$Prefix' -PrimaryZone '$primaryZone'")
}

function Get-TXTStripeBytes {
    <#
    .SYNOPSIS
        Extracts a striped file from DNS TXT records and returns it as a byte array.

    .DESCRIPTION
        Reads the stripe-meta record from the primary zone to discover the full
        zones list, then fetches all chunks from the appropriate zones in order,
        reassembles them, verifies the SHA-256 hash, and returns the raw bytes.
        No files are written to disk.

    .PARAMETER Prefix
        The prefix used when the file was uploaded with Publish-TXTStripe.

    .PARAMETER PrimaryZone
        The first zone in the stripe (where the stripe-meta record lives).

    .PARAMETER DnsServer
        Optional DNS resolver IP (e.g. '1.1.1.1').

    .EXAMPLE
        $bytes = Get-TXTStripeBytes -Prefix 'doom' -PrimaryZone 'example.com'
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [string]$Prefix,
        [Parameter(Mandatory)] [string]$PrimaryZone,
        [string]$DnsServer
    )

    function Resolve-TXT {
        param([string]$Name)
        $params = @{ Name = $Name; Type = 'TXT'; ErrorAction = 'Stop' }
        if ($DnsServer) { $params['Server'] = $DnsServer }
        try {
            $result = Resolve-DnsName @params
            return ($result | Where-Object { $_.Type -eq 'TXT' } | Select-Object -First 1).Strings -join ''
        } catch { throw "DNS resolution failed for '$Name': $_" }
    }

    # ── Read stripe-meta ───────────────────────────────────────────────────────
    $metaName = "$Prefix-stripe-meta.$PrimaryZone"
    Write-Host "Querying stripe-meta: $metaName" -ForegroundColor Cyan

    $metaRaw = Resolve-TXT -Name $metaName
    try { $meta = $metaRaw | ConvertFrom-Json }
    catch { throw "stripe-meta could not be parsed as JSON. Raw: $metaRaw" }

    $totalChunks    = [int]$meta.chunks
    $expectedHash   = $meta.sha256
    $origFilename   = $meta.filename
    $expectedSize   = [long]$meta.size
    $zones          = @($meta.zones)
    $isCompressed   = [bool]($meta.PSObject.Properties['compressed'] -and $meta.compressed)

    # Support variable per-zone capacities (new) and uniform chunks_per_zone (old)
    if ($meta.PSObject.Properties['zone_capacities'] -and $meta.zone_capacities) {
        $zoneCapacities = @($meta.zone_capacities | ForEach-Object { [int]$_ })
    } else {
        $cpz = [int]$meta.chunks_per_zone
        $zoneCapacities = @($zones | ForEach-Object { $cpz })
    }
    # Build cumulative zone starts
    $zoneStarts = [int[]]::new($zones.Count)
    $cum = 0
    for ($j = 0; $j -lt $zones.Count; $j++) { $zoneStarts[$j] = $cum; $cum += $zoneCapacities[$j] }

    Write-Host "  File     : $origFilename" -ForegroundColor Cyan
    Write-Host ("  Size     : {0:N0} bytes" -f $expectedSize) -ForegroundColor Cyan
    Write-Host ("  Chunks   : {0:N0} across {1} zone(s){2}" -f $totalChunks, $zones.Count, $(if ($isCompressed) { ' (GZip compressed)' } else { '' })) -ForegroundColor Cyan

    # ── Fetch all chunks ───────────────────────────────────────────────────────
    $sb = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $totalChunks; $i++) {
        # Map chunk index to zone using cumulative starts
        $zIdx = $zones.Count - 1
        for ($j = 0; $j -lt $zones.Count; $j++) { if ($i -lt $zoneStarts[$j] + $zoneCapacities[$j]) { $zIdx = $j; break } }
        $zone      = $zones[$zIdx]
        $chunkName = "$Prefix-$i.$zone"

        Write-Progress `
            -Activity "Downloading stripe from DNS" `
            -Status   ("Chunk {0}/{1} from {2}" -f ($i + 1), $totalChunks, $zone) `
            -PercentComplete ([Math]::Round(($i / $totalChunks) * 100))

        $chunk = Resolve-TXT -Name $chunkName
        if ([string]::IsNullOrEmpty($chunk)) {
            throw "Chunk $i ('$chunkName') returned empty or null."
        }
        $sb.Append($chunk) | Out-Null
    }

    Write-Progress -Activity "Downloading stripe from DNS" -Completed

    # ── Decode and verify ──────────────────────────────────────────────────────
    Write-Host 'Decoding Base64...' -ForegroundColor Cyan
    try { $rawBytes = [Convert]::FromBase64String($sb.ToString()) }
    catch { throw "Base64 decode failed: $_" }

    # ── Decompress if the stripe was uploaded with -Compress ──────────────────
    if ($isCompressed) {
        Write-Host 'Decompressing (GZip)...' -ForegroundColor Cyan
        try {
            $cmpIn   = [System.IO.MemoryStream]::new($rawBytes, $false)
            $cmpOut  = [System.IO.MemoryStream]::new()
            $gzip    = [System.IO.Compression.GZipStream]::new($cmpIn, [System.IO.Compression.CompressionMode]::Decompress)
            $gzip.CopyTo($cmpOut)
            $gzip.Dispose()
            $fileBytes = $cmpOut.ToArray()
        } catch { throw "GZip decompression failed: $_" }
    } else {
        $fileBytes = $rawBytes
    }

    Write-Host 'Verifying SHA-256...' -ForegroundColor Cyan
    $sha256     = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes  = $sha256.ComputeHash($fileBytes)
    $actualHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    if ($actualHash -ne $expectedHash) {
        Write-Warning "Hash mismatch! Expected: $expectedHash  Actual: $actualHash"
    } else {
        Write-Host '  ✓ Hash verified.' -ForegroundColor Green
    }

    Write-Host ("✓ {0:N0} bytes loaded into memory." -f $fileBytes.Length) -ForegroundColor Green
    return ,$fileBytes
}

function Get-TXTStripe {
    <#
    .SYNOPSIS
        Extracts a striped file from DNS TXT records and writes it to disk.

    .PARAMETER Prefix
        The prefix used during upload.

    .PARAMETER PrimaryZone
        The first zone in the stripe (where stripe-meta lives).

    .PARAMETER Path
        Output file path. Defaults to the original filename in the current directory.

    .PARAMETER DnsServer
        Optional DNS resolver IP.

    .PARAMETER Force
        Overwrite the output file if it already exists.

    .EXAMPLE
        Get-TXTStripe -Prefix 'doom' -PrimaryZone 'example.com' -Path 'DOOM1.WAD'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prefix,
        [Parameter(Mandatory)] [string]$PrimaryZone,
        [string]$Path,
        [string]$DnsServer,
        [switch]$Force
    )

    # Resolve default output path from meta before fetching (avoids a second DNS lookup)
    if (-not $Path) {
        $dnsParams = @{ Name = "$Prefix-stripe-meta.$PrimaryZone"; Type = 'TXT'; ErrorAction = 'Stop' }
        if ($DnsServer) { $dnsParams['Server'] = $DnsServer }
        $metaObj = ((Resolve-DnsName @dnsParams) | Where-Object { $_.Type -eq 'TXT' } | Select-Object -First 1).Strings -join '' | ConvertFrom-Json
        $Path    = Join-Path (Get-Location) $metaObj.filename
        Write-Host "  Output path : $Path (from stripe-meta)" -ForegroundColor Yellow
    }

    $getParams = @{ Prefix = $Prefix; PrimaryZone = $PrimaryZone }
    if ($DnsServer) { $getParams['DnsServer'] = $DnsServer }

    $fileBytes = Get-TXTStripeBytes @getParams

    if ((Test-Path $Path) -and -not $Force) {
        throw "Output file '$Path' already exists. Use -Force to overwrite."
    }

    [System.IO.File]::WriteAllBytes($Path, $fileBytes)
    Write-Host "✓ Written to: $Path" -ForegroundColor Green
}

function Remove-TXTStripe {
    <#
    .SYNOPSIS
        Deletes all DNS TXT records for a stripe upload across all its zones.

    .DESCRIPTION
        Reads the stripe-meta from the primary zone to discover the zones list,
        then deletes all matching chunk records from each zone and finally removes
        the stripe-meta record itself. Requires API credentials.

    .PARAMETER Prefix
        The prefix used during upload.

    .PARAMETER PrimaryZone
        The first zone in the stripe (where stripe-meta lives).

    .PARAMETER Force
        Skip the confirmation prompt.

    .EXAMPLE
        Remove-TXTStripe -Prefix 'doom' -PrimaryZone 'example.com'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string]$Prefix,
        [Parameter(Mandatory)] [string]$PrimaryZone,
        [switch]$Force
    )

    # Read stripe-meta for zones list
    $primaryZoneId  = Get-ZoneId -Zone $PrimaryZone
    $stripeMetaName = "$Prefix-stripe-meta"

    $smLookup = Invoke-RestMethod `
        -Uri     ("$Script:CF_API/zones/$primaryZoneId/dns_records?type=TXT&name=$stripeMetaName.$PrimaryZone") `
        -Headers (Get-CFHeaders) -Method Get

    if (-not $smLookup.success -or $smLookup.result.Count -eq 0) {
        throw "No stripe-meta found for prefix '$Prefix' in zone '$PrimaryZone'."
    }

    $meta          = $smLookup.result[0].content | ConvertFrom-Json
    $stripeMetaId  = $smLookup.result[0].id
    $zones         = @($meta.zones)

    if (-not $Force -and -not $PSCmdlet.ShouldProcess(
            "$Prefix-* across $($zones -join ', ')", 'Delete all stripe TXT records')) { return }

    Write-Host ("Removing stripe '{0}' across {1} zone(s)..." -f $Prefix, $zones.Count) -ForegroundColor Cyan

    foreach ($z in $zones) {
        $zId = Get-ZoneId -Zone $z
        Write-Host "  Cleaning $z..." -ForegroundColor DarkCyan
        Remove-CFTXTRecordsByPrefix -ZoneId $zId -Prefix $Prefix -Zone $z
    }

    # Delete stripe-meta last
    Invoke-RestMethod -Uri "$Script:CF_API/zones/$primaryZoneId/dns_records/$stripeMetaId" `
        -Headers (Get-CFHeaders) -Method Delete | Out-Null

    Write-Host ("✓ Stripe '{0}' removed from {1} zone(s)." -f $Prefix, $zones.Count) -ForegroundColor Green
}

function Get-TXTStripeList {
    <#
    .SYNOPSIS
        Lists all stripe uploads stored in a primary zone.

    .PARAMETER PrimaryZone
        The zone to scan for stripe-meta records.

    .EXAMPLE
        Get-TXTStripeList -PrimaryZone 'example.com'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PrimaryZone)

    $zoneId  = Get-ZoneId -Zone $PrimaryZone
    $page    = 1
    $results = [System.Collections.Generic.List[object]]::new()

    do {
        $response = Invoke-RestMethod `
            -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT&per_page=100&page=$page") `
            -Headers (Get-CFHeaders) -Method Get
        if (-not $response.success) { break }
        foreach ($r in $response.result) {
            if ($r.name -match '^(.+)-stripe-meta\.') {
                try {
                    $m = $r.content | ConvertFrom-Json
                    $results.Add([PSCustomObject]@{
                        Prefix        = $Matches[1]
                        Filename      = $m.filename
                        Size          = $m.size
                        Chunks        = $m.chunks
                        Zones         = ($m.zones -join ', ')
                        ChunksPerZone = $m.chunks_per_zone
                        SHA256        = $m.sha256
                    })
                } catch {}
            }
        }
        $page++
    } while ($response.result_info.page -lt $response.result_info.total_pages)

    return $results
}

function Remove-TXTRecord {
    <#
    .SYNOPSIS
        Removes all DNS TXT records associated with a stored file.

    .DESCRIPTION
        Deletes all records matching <Prefix>-*.<Zone> from Cloudflare DNS,
        including the metadata record. Requires API credentials.

    .PARAMETER Zone
        The DNS zone containing the records (e.g. "example.com").

    .PARAMETER Prefix
        The subdomain prefix of the file to remove (e.g. "clip").

    .PARAMETER Force
        Skip the confirmation prompt.

    .EXAMPLE
        Remove-TXTRecord -Zone 'example.com' -Prefix 'clip'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$Zone,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [switch]$Force
    )

    Write-Verbose "Resolving Zone ID for '$Zone'..."

    # Phase 1 — resolve zone (shown as an indeterminate progress bar while the API call runs)
    Write-Progress -Activity "Remove-TXTRecord: $Prefix.$Zone" -Status 'Resolving zone ID...' -PercentComplete 0
    $zoneId = Get-ZoneId -Zone $Zone

    if ($Force -or $PSCmdlet.ShouldProcess("$Prefix-*.$Zone", 'Delete all matching TXT records')) {

        # Phase 2 — discover matching records (paginated scan)
        Write-Progress -Activity "Remove-TXTRecord: $Prefix.$Zone" -Status 'Scanning for records to remove...' -PercentComplete 10

        # Collect matching record IDs with a progress-aware scan so the user can
        # see activity during large zones that span multiple API pages.
        $page     = 1
        $toDelete = [System.Collections.Generic.List[string]]::new()

        do {
            Write-Progress `
                -Activity "Remove-TXTRecord: $Prefix.$Zone" `
                -Status   ("Scanning zone page {0} for records matching '{1}-*'..." -f $page, $Prefix) `
                -PercentComplete ([Math]::Min(10 + $page * 5, 40))   # crawl up to ~40% during scan

            $response = Invoke-RestMethod `
                -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT&per_page=100&page=$page") `
                -Headers (Get-CFHeaders) `
                -Method  Get

            if (-not $response.success) { break }

            foreach ($record in $response.result) {
                if ($record.name -like "$Prefix-*.$Zone" -or $record.name -like "$Prefix-*") {
                    $toDelete.Add($record.id)
                }
            }
            $page++
        } while ($response.result_info.page -lt $response.result_info.total_pages)

        $totalToDelete = $toDelete.Count

        if ($totalToDelete -eq 0) {
            Write-Progress -Activity "Remove-TXTRecord: $Prefix.$Zone" -Completed
            Write-Host "No records found with prefix '$Prefix' in zone '$Zone'." -ForegroundColor Yellow
            return
        }

        Write-Host ("Found {0} record(s) to delete." -f $totalToDelete) -ForegroundColor Cyan
        Write-Host  "  (Auto-throttled: 3 req/sec, 3 concurrent, 429-aware backoff)" -ForegroundColor DarkCyan

        # Phase 3 — delete records in parallel using the same token-bucket + SemaphoreSlim
        # pattern as Publish-TXTRecord. Each task fires one DELETE request, backs off on
        # 429, and retries up to CF_MAX_RETRIES times before recording a failure.
        $delResults   = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
        $delProgress  = [System.Collections.Concurrent.ConcurrentBag[byte]]::new()
        $dRateState              = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        $dRateState['lock']      = [object]::new()
        $dRateState['nextAt']    = [System.Diagnostics.Stopwatch]::GetTimestamp()
        $dRateState['ticksPer']  = [long]([System.Diagnostics.Stopwatch]::Frequency / $Script:CF_RATE_LIMIT_RPS)

        $dPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Script:CF_MAX_CONCURRENCY)
        $dPool.Open()

        $dWorker = {
            param($recId, $zoneId, $cfApi, $cfToken,
                  $delResults, $delProgress, $dRateState,
                  $delMaxRetry, $del429Base, $del429Max)
            try {
                $attempt  = 0
                $waitSecs = $del429Base
                $done     = $false
                while (-not $done -and $attempt -lt $delMaxRetry) {
                    [System.Threading.Monitor]::Enter($dRateState['lock'])
                    try {
                        $now = [System.Diagnostics.Stopwatch]::GetTimestamp()
                        if ($now -lt $dRateState['nextAt']) {
                            $ms = [long](($dRateState['nextAt'] - $now) * 1000 / [System.Diagnostics.Stopwatch]::Frequency)
                            if ($ms -gt 0) { [System.Threading.Thread]::Sleep($ms) }
                        }
                        $dRateState['nextAt'] = [System.Diagnostics.Stopwatch]::GetTimestamp() + $dRateState['ticksPer']
                    } finally { [System.Threading.Monitor]::Exit($dRateState['lock']) }

                    try {
                        Invoke-RestMethod -Uri "$cfApi/zones/$zoneId/dns_records/$recId" `
                            -Headers @{ Authorization="Bearer $cfToken"; 'Content-Type'='application/json' } `
                            -Method Delete -ErrorAction Stop | Out-Null
                        $delResults[$recId] = 'ok'
                        $done = $true
                    } catch {
                        $e = $_.ToString()
                        if ($e -match '429|Too Many Requests') {
                            $attempt++
                            $retryAfter = $waitSecs
                            if ($e -match 'Retry-After:\s*(\d+)') { $retryAfter = [int]$Matches[1] }
                            [System.Threading.Thread]::Sleep($retryAfter * 1000)
                            $waitSecs = [Math]::Min($waitSecs * 2, $del429Max)
                        } else { $delResults[$recId] = "ERROR:$e"; $done = $true }
                    }
                }
                if (-not $done) { $delResults[$recId] = 'ERROR:max retries exceeded' }
            } finally { $delProgress.Add(0) | Out-Null }
        }

        $dJobs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($id in $toDelete) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $dPool
            $null = $ps.AddScript($dWorker)
            $null = $ps.AddParameter('recId',       $id)
            $null = $ps.AddParameter('zoneId',      $zoneId)
            $null = $ps.AddParameter('cfApi',       $Script:CF_API)
            $null = $ps.AddParameter('cfToken',     $Script:CFApiToken)
            $null = $ps.AddParameter('delResults',  $delResults)
            $null = $ps.AddParameter('delProgress', $delProgress)
            $null = $ps.AddParameter('dRateState',  $dRateState)
            $null = $ps.AddParameter('delMaxRetry', $Script:CF_MAX_RETRIES)
            $null = $ps.AddParameter('del429Base',  $Script:CF_429_BASE_WAIT)
            $null = $ps.AddParameter('del429Max',   $Script:CF_429_MAX_WAIT)
            $dJobs.Add(@{ PS = $ps; AR = $ps.BeginInvoke() })

            $done = $delProgress.Count
            $pct  = 40 + [Math]::Round(($done / [Math]::Max($totalToDelete, 1)) * 60)
            Write-Progress -Activity "Remove-TXTRecord: $Prefix.$Zone" `
                -Status ("Deleted {0}/{1}" -f $done, $totalToDelete) `
                -PercentComplete $pct
        }

        do {
            Start-Sleep -Milliseconds 500
            $done = $delProgress.Count
            $pct  = 40 + [Math]::Round(($done / [Math]::Max($totalToDelete, 1)) * 60)
            Write-Progress -Activity "Remove-TXTRecord: $Prefix.$Zone" `
                -Status ("Deleted {0}/{1}" -f $done, $totalToDelete) `
                -PercentComplete $pct
        } while ($delProgress.Count -lt $toDelete.Count)

        foreach ($j in $dJobs) { $j.PS.Dispose() }
        $dPool.Close(); $dPool.Dispose()
        Write-Progress -Activity "Remove-TXTRecord: $Prefix.$Zone" -Completed

        # Tally results and report any failures
        $deletedCount = 0
        $failedCount  = 0
        foreach ($kvp in $delResults.GetEnumerator()) {
            if ($kvp.Value -eq 'ok') { $deletedCount++ }
            else {
                $failedCount++
                Write-Warning ("Failed to delete record '{0}': {1}" -f $kvp.Key, $kvp.Value.Substring(6))
            }
        }

        if ($failedCount -gt 0) {
            Write-Host ("✓ Removed {0} record(s). {1} failed — re-run to retry." -f $deletedCount, $failedCount) -ForegroundColor Yellow
        } else {
            Write-Host ("✓ Removed {0} record(s) with prefix '{1}' from {2}." -f $deletedCount, $Prefix, $Zone) -ForegroundColor Green
        }
    }
}

function Get-TXTRecordList {
    <#
    .SYNOPSIS
        Lists files stored as TXT records in a Cloudflare DNS zone.

    .DESCRIPTION
        Scans all TXT records in the zone for records ending in "-meta.<zone>",
        which indicates a file uploaded by this module. Returns metadata for each.
        Requires API credentials.

    .PARAMETER Zone
        The DNS zone to scan (e.g. "example.com").

    .EXAMPLE
        Get-TXTRecordList -Zone 'example.com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Zone
    )

    $zoneId = Get-ZoneId -Zone $Zone
    $page   = 1
    $found  = [System.Collections.Generic.List[object]]::new()

    do {
        $response = Invoke-RestMethod `
            -Uri     ("$Script:CF_API/zones/$zoneId/dns_records?type=TXT" + "&per_page=100&page=$page") `
            -Headers (Get-CFHeaders) `
            -Method  Get

        foreach ($record in $response.result) {
            # Metadata records are named "<prefix>-meta.<zone>"
            if ($record.name -match "^(.+)-meta\.$([regex]::Escape($Zone))$") {
                $prefixName = $Matches[1]
                try {
                    $meta = $record.content | ConvertFrom-Json
                    $found.Add([PSCustomObject]@{
                        Prefix   = $prefixName
                        Filename = $meta.filename
                        Chunks   = $meta.chunks
                        Size     = $meta.size
                        SHA256   = $meta.sha256
                        Record   = $record.name
                    })
                } catch {
                    # Record exists but isn't valid metadata — skip it
                }
            }
        }
        $page++
    } while ($response.result_info.page -lt $response.result_info.total_pages)

    if ($found.Count -eq 0) {
        Write-Host "No TXTRecords files found in zone '$Zone'." -ForegroundColor Yellow
    }

    return $found
}

# ──────────────────────────────────────────────────────────────────────────────
# MODULE EXPORTS
# ──────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Set-CFCredential'
    'Get-CFZone'
    'Publish-TXTRecord'
    'Get-TXTRecord'
    'Remove-TXTRecord'
    'Get-TXTRecordList'
    'Publish-TXTStripe'
    'Get-TXTStripeBytes'
    'Get-TXTStripe'
    'Remove-TXTStripe'
    'Get-TXTStripeList'
)
