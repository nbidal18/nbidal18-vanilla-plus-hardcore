<#
    Fetches everything the channel serves and checks it against the local build.

    This is the only check that can see a whole class of failure: the build and the repo can both be
    correct while the SERVED bytes differ. That happened - a repo-wide `*.json text eol=lf` rule
    normalised line endings on commit, five of twelve sampled configs stopped matching their own
    index hashes, and the updater would have redownloaded them on every launch for ever without
    converging. Nothing local reveals it.

    Run it after Pages has deployed and before deploying the server policy.

      scripts\Verify-PublishedChannel.ps1
      scripts\Verify-PublishedChannel.ps1 -Retired 'mods/nbidal18-integrity-1.0.4+26.2-fabric.jar'
      scripts\Verify-PublishedChannel.ps1 -WaitForPropagation 900    right after a push: waits for
                                                                    Pages, then judges once

    Checks, per file:
      served bytes == the local build's bytes
      served bytes == the sha256 index.toml records (which is what the updater enforces)
    and once:
      the served manifest's packVersion matches PACK-VERSION.txt
      the served manifest's digest matches the policy this release generated
      every -Retired path returns 404
      the live engine jars are NOT served (packwiz must never overwrite a running jar)

    Exits 1 on any failure, so it can gate a publish.
#>
[CmdletBinding()]
param(
    # Default: the channel this repository publishes, from UPDATE-URL.txt with pack.toml stripped.
    # It used to spell out the Vanilla+ URL, so on the hardcore line a run with no -BaseUrl verified
    # the wrong channel and passed (2026-09-24).
    [string] $BaseUrl = ((Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'UPDATE-URL.txt') -Raw).Trim() -replace 'pack\.toml$', ''),
    [string[]] $Retired = @(),
    [int] $TimeoutSec = 60,
    # Seconds to wait for GitHub Pages to serve THIS build before judging it. 0 judges immediately.
    # Pages takes a few minutes after a push, and its CDN can hand out one stale file for a while
    # after the rest has flipped - both were being handled from outside on 2026-09-24 by re-running
    # this whole script in a loop, which re-downloaded the entire channel each time (266 MB, five
    # times) and whose success test was wrong twice. The wait belongs in here: first the served
    # manifest is polled (a few KB) until it is this build's, then the full pass runs once, then
    # only the files that still disagree are re-fetched until they agree or the time is up.
    [int] $WaitForPropagation = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$clientZip = (Get-Content -LiteralPath (Join-Path $repo 'CLIENT-ZIP.txt') -Raw).Trim()
if (-not $clientZip.EndsWith('.zip')) { throw "CLIENT-ZIP.txt is '$clientZip'; it must name a .zip." }
$site = Join-Path $repo 'site'
if (-not (Test-Path -LiteralPath $site)) { throw "No site\ at $site - run Build-Release.ps1 first" }
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()

Add-Type -AssemblyName System.Net.Http
$client = New-Object Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
$client.DefaultRequestHeaders.Add('User-Agent', 'nbidal18-verify')

# Pack filenames carry spaces, apostrophes, U+2019, ampersands and section signs. Unescaped they
# produce a request that fails in a way indistinguishable from a 404.
function Get-Url([string] $rel) {
    $encoded = ($rel -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return $BaseUrl + $encoded
}

# Retried, because one blip out of 250 requests should not read as a broken release.
#
# The first run of this script failed a publish on config/presencefootsteps/updater.json, which was
# being served perfectly - three manual fetches returned 200 and the right hash seconds later. A
# check that cries wolf gets ignored, and an ignored check is worse than none.
#
# 404 and 410 are answers, not failures, so they are not retried: a retired file must fail fast.
function Get-Served([string] $rel, [int] $Attempts = 3) {
    $url = Get-Url $rel
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            if ($response.IsSuccessStatusCode) {
                return $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            }
            $code = [int] $response.StatusCode
            if ($code -eq 404 -or $code -eq 410) { return $null }
            $reason = "HTTP $code"
        }
        catch { $reason = $_.Exception.GetBaseException().Message }
        if ($attempt -lt $Attempts) {
            Write-Host ("retry     {0} ({1}, attempt {2}/{3})" -f $rel, $reason, $attempt, $Attempts)
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    return $null
}

function Get-Sha([byte[]] $bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

$deadline = (Get-Date).AddSeconds($WaitForPropagation)

# ---------------------------------------------------------------- wait for Pages to flip
# The manifest is the file whose hash the server enforces, so "the channel serves this build" means
# exactly "the served manifest hashes like the local one". Polled alone, cheaply, before anything
# else is fetched; one line when the wait starts and one when it ends, not one per poll.
$localManifestSha = Get-Sha ([IO.File]::ReadAllBytes((Join-Path $site 'sync-manifest.json')))
if ($WaitForPropagation -gt 0) {
    $announced = $false
    $started = Get-Date
    while ($true) {
        $served = Get-Served 'sync-manifest.json' 1
        $servedSha = if ($null -ne $served) { Get-Sha $served } else { '(unreachable)' }
        if ($servedSha -eq $localManifestSha) {
            if ($announced) { Write-Host ("propagated after {0:N0} s" -f ((Get-Date) - $started).TotalSeconds) }
            break
        }
        if ((Get-Date) -ge $deadline) {
            Write-Host ("waited    {0} s and the channel still serves manifest {1}, not this build's {2}" -f $WaitForPropagation, $servedSha.Substring(0, 16), $localManifestSha.Substring(0, 16))
            break
        }
        if (-not $announced) {
            Write-Host ("waiting   for Pages: served manifest {0}, this build is {1} (up to {2} s)" -f $servedSha.Substring(0, 16), $localManifestSha.Substring(0, 16), $WaitForPropagation)
            $announced = $true
        }
        Start-Sleep -Seconds 20
    }
}

# ---------------------------------------------------------------- indexed files
$indexText = [IO.File]::ReadAllText((Join-Path $site 'index.toml'))
$entries = [regex]::Matches($indexText, '(?m)^file = "(?<f>.+)"\r?\nhash = "(?<h>[0-9a-f]{64})"')
if ($entries.Count -eq 0) { throw 'index.toml lists no file/hash pairs' }
Write-Host ("index     {0} files listed" -f $entries.Count)

$badLocal = New-Object Collections.Generic.List[string]
$badHash = New-Object Collections.Generic.List[string]
$missing = New-Object Collections.Generic.List[string]

# One file, judged: fetched, compared with the index hash (when indexed) and with the local build.
# Returns $true when it agrees on every count, so the same function serves the first pass and the
# re-fetch of whatever the CDN was still serving stale.
function Test-File([string] $rel, [string] $want, [bool] $record) {
    $served = Get-Served $rel
    if ($null -eq $served) { if ($record) { $missing.Add($rel) }; return $false }
    $ok = $true
    $servedSha = Get-Sha $served
    if ($want -and $servedSha -ne $want) { if ($record) { $badHash.Add($rel) }; $ok = $false }
    $local = Join-Path $site ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $local)) {
        if ($record) { $missing.Add("$rel (indexed and served, but not in the local build)") }
        return $false
    }
    if ((Get-Sha ([IO.File]::ReadAllBytes($local))) -ne $servedSha) { if ($record) { $badLocal.Add($rel) }; $ok = $false }
    return $ok
}

$wanted = [ordered]@{}
foreach ($entry in $entries) { $wanted[$entry.Groups['f'].Value] = $entry.Groups['h'].Value }
foreach ($rel in 'pack.toml', 'index.toml', 'sync-manifest.json', 'SHA256SUMS.txt', $clientZip) {
    if (-not $wanted.Contains($rel)) { $wanted[$rel] = '' }   # fetched directly, not indexed: local-build check only
}

$disagreeing = New-Object Collections.Generic.List[string]
$done = 0
foreach ($rel in $wanted.Keys) {
    if (-not (Test-File $rel $wanted[$rel] $false)) { $disagreeing.Add($rel) }
    $done++
    if ($done % 50 -eq 0) { Write-Host ("          {0}/{1} ..." -f $done, $wanted.Count) }
}
Write-Host ("checked   {0} indexed files and 5 directly-fetched artefacts" -f $entries.Count)

# A CDN edge can keep serving the previous build's copy of one file for minutes after the rest has
# flipped (bcc-common.json, 2026-09-24: stale on the first pass, fresh on the second). Only the files
# that disagreed are asked again, so the wait costs kilobytes rather than the whole channel.
if ($disagreeing.Count -and $WaitForPropagation -gt 0) {
    Write-Host ("stale?    {0} file(s) disagree; re-fetching only those until they agree or the wait is up" -f $disagreeing.Count)
    while ($disagreeing.Count -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $still = New-Object Collections.Generic.List[string]
        foreach ($rel in $disagreeing) { if (-not (Test-File $rel $wanted[$rel] $false)) { $still.Add($rel) } }
        $disagreeing = $still
    }
}
# Whatever still disagrees is recorded for the verdict, with the reason.
foreach ($rel in $disagreeing) { [void] (Test-File $rel $wanted[$rel] $true) }

# ---------------------------------------------------------------- the manifest agrees with itself
$manifestBytes = Get-Served 'sync-manifest.json'
$problems = New-Object Collections.Generic.List[string]
if ($null -eq $manifestBytes) {
    $problems.Add('sync-manifest.json is not being served at all')
}
else {
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    if ($manifest.packVersion -ne $version) {
        $problems.Add("the served manifest says packVersion $($manifest.packVersion), PACK-VERSION.txt says $version")
    }
    $digest = Get-Sha $manifestBytes
    $prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
    $policy = Join-Path (Split-Path -Parent $repo) ("$prefix$version\4. server\nbidal18-integrity.properties")
    if (Test-Path -LiteralPath $policy) {
        $expected = (Select-String -LiteralPath $policy -Pattern '^expected-manifest-sha256=(.+)$').Matches[0].Groups[1].Value
        if ($expected -ne $digest) {
            $problems.Add("the policy expects $($expected.Substring(0,16))... but the channel serves $($digest.Substring(0,16))...")
        }
    }
    else { $problems.Add("no server policy at $policy") }
    Write-Host ("manifest  packVersion {0}, digest {1}" -f $manifest.packVersion, $digest.Substring(0, 16))
}

# ---------------------------------------------------------------- what must NOT be served
$stillServed = New-Object Collections.Generic.List[string]
foreach ($rel in $Retired) { if ($null -ne (Get-Served $rel)) { $stillServed.Add($rel) } }
foreach ($rel in 'nbidal18-packwiz-sync.jar', 'nbidal18-packwiz-updater.jar') {
    if ($null -ne (Get-Served $rel)) {
        $stillServed.Add("$rel (a live engine jar - packwiz would overwrite the running sync)")
    }
}

# ---------------------------------------------------------------- verdict
Write-Host ''
Write-Host ("served != local build     : {0}" -f $(if ($badLocal.Count) { $badLocal -join ', ' } else { 'none' }))
Write-Host ("served != index hash      : {0}" -f $(if ($badHash.Count) { $badHash -join ', ' } else { 'none' }))
Write-Host ("unreachable               : {0}" -f $(if ($missing.Count) { $missing -join ', ' } else { 'none' }))
Write-Host ("served but should not be  : {0}" -f $(if ($stillServed.Count) { $stillServed -join ', ' } else { 'none' }))
foreach ($p in $problems) { Write-Host "manifest problem          : $p" }

$client.Dispose()
if ($badLocal.Count -or $badHash.Count -or $missing.Count -or $stillServed.Count -or $problems.Count) {
    throw 'The published channel does not match this build. Do NOT deploy the server policy.'
}
Write-Host ''
Write-Host 'OK        the channel serves exactly what was built'
