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
    [string] $BaseUrl = 'https://nbidal18.github.io/nbidal18-vanilla-plus/',
    [string[]] $Retired = @(),
    [int] $TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
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

# ---------------------------------------------------------------- indexed files
$indexText = [IO.File]::ReadAllText((Join-Path $site 'index.toml'))
$entries = [regex]::Matches($indexText, '(?m)^file = "(?<f>.+)"\r?\nhash = "(?<h>[0-9a-f]{64})"')
if ($entries.Count -eq 0) { throw 'index.toml lists no file/hash pairs' }
Write-Host ("index     {0} files listed" -f $entries.Count)

$badLocal = New-Object Collections.Generic.List[string]
$badHash = New-Object Collections.Generic.List[string]
$missing = New-Object Collections.Generic.List[string]
$done = 0

foreach ($entry in $entries) {
    $rel = $entry.Groups['f'].Value
    $want = $entry.Groups['h'].Value
    $served = Get-Served $rel
    if ($null -eq $served) { $missing.Add($rel); continue }

    if ((Get-Sha $served) -ne $want) { $badHash.Add($rel) }

    $local = Join-Path $site ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $local)) {
        $missing.Add("$rel (indexed and served, but not in the local build)")
    }
    elseif ((Get-Sha ([IO.File]::ReadAllBytes($local))) -ne (Get-Sha $served)) {
        $badLocal.Add($rel)
    }

    $done++
    if ($done % 50 -eq 0) { Write-Host ("          {0}/{1} ..." -f $done, $entries.Count) }
}
Write-Host ("checked   {0} indexed files" -f $done)

# ---------------------------------------------------------------- fetched directly, not indexed
foreach ($rel in 'pack.toml', 'index.toml', 'sync-manifest.json', 'SHA256SUMS.txt', 'nbidal18-client.zip') {
    $served = Get-Served $rel
    if ($null -eq $served) { $missing.Add($rel); continue }
    $local = Join-Path $site $rel
    if ((Get-Sha ([IO.File]::ReadAllBytes($local))) -ne (Get-Sha $served)) { $badLocal.Add($rel) }
}
Write-Host 'checked   5 directly-fetched artefacts'

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
