<#
    Builds the whole release, in the only order that works, and refuses to finish if the result is
    incomplete.

    The order matters and is not obvious, and it changed in v1.0.3.

    Build-Updater now runs FIRST, because it only writes to client\ and Build-PackwizSite has to
    stage its .next.jar copies into site\ BEFORE refreshing the index. Anything staged after the
    refresh is served and listed nowhere, so packwiz never downloads it. That is exactly what
    happened from v1.0.0 to v1.0.2: the four staged jars sat on the channel unindexed, every
    instance kept the update engine its client ZIP shipped, and the self-update path was inert.

    Build-PackwizSite still WIPES site\ before staging, so nothing that writes there may run first.

    Checksums are written here rather than inside Build-PackwizSite, because SHA256SUMS.txt has to
    cover the client ZIP, which is added after staging.
#>
[CmdletBinding()]
param(
    # Passed through to Build-PackwizSite: a player-class file that is meant to be re-delivered over
    # every player's copy this release. Without it the build refuses a changed player file.
    [string[]] $RedeliverPlayerFile = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A version that already has a CHANGELOG entry has reached players - an entry means exactly that.
# Rebuilding into it silently rewrites what the archive says shipped, and the built site then
# disagrees with the digest the live server accepts.
#
# This has happened three times - v1.0.15, v1.0.17 and v1.0.19 - each caught by hand afterwards and
# each needing the release folder restored from the published bytes. New-Release makes cutting the
# next version cheap; this makes forgetting to expensive.
function Assert-VersionUnpublished([string] $version, [string] $repoRoot) {
    $changelog = Join-Path $repoRoot 'CHANGELOG.md'
    if (-not (Test-Path -LiteralPath $changelog)) { return }
    $heading = '## v' + $version
    foreach ($line in [IO.File]::ReadAllLines($changelog)) {
        if ($line.Trim() -eq $heading) {
            throw ("v$version already has a CHANGELOG entry, so it has been published. Run " +
                "scripts/New-Release.ps1 to cut the next version and build into that instead.")
        }
    }
}


$repo = Split-Path -Parent $PSScriptRoot
$clientZip = (Get-Content -LiteralPath (Join-Path $repo 'CLIENT-ZIP.txt') -Raw).Trim()
if (-not $clientZip.EndsWith('.zip')) { throw "CLIENT-ZIP.txt is '$clientZip'; it must name a .zip." }
# Before anything is built, not after: the sub-scripts below wipe and regenerate site\, so a late
# check still rewrites the published release before refusing.
Assert-VersionUnpublished ((Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()) $repo
$site = Join-Path $repo 'site'

Write-Host "== 1/4 updater jars"
& (Join-Path $PSScriptRoot 'Build-Updater.ps1')
Write-Host "`n== 2/4 pack content"
& (Join-Path $PSScriptRoot 'Build-PackwizSite.ps1') -RedeliverPlayerFile $RedeliverPlayerFile
Write-Host "`n== 3/4 client shell"
& (Join-Path $PSScriptRoot 'Build-ClientShell.ps1') | Select-Object -First 1

Write-Host "`n== 4/4 checksums and release gate"
$sums = New-Object Text.StringBuilder
Get-ChildItem -LiteralPath $site -Recurse -File | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($site.Length + 1).Replace('\', '/')
    if ($rel -eq 'SHA256SUMS.txt') { return }
    $null = $sums.AppendFormat("{0}  {1}`n", (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel)
}
[IO.File]::WriteAllText((Join-Path $site 'SHA256SUMS.txt'), $sums.ToString(), (New-Object Text.UTF8Encoding($false)))

# Fetched directly by the updater rather than through the packwiz index.
$required = @(
    'pack.toml', 'index.toml', 'sync-manifest.json', 'SHA256SUMS.txt', $clientZip
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $site $_)) })
if ($missing.Count) { throw ("The release is incomplete; these are missing from site\: " + ($missing -join ', ')) }

# The update engine reaches a player ONLY by being in the index - packwiz downloads what the index
# lists, and the supervisor promotes what packwiz delivered. Presence in site\ proves nothing.
#
# The old gate checked exactly that: it required these files to exist, they did, and it reported
# "ready to publish" for three releases while none of them was listed and no instance could ever
# receive a new update engine. Check the index, not the directory.
$mustBeIndexed = @(
    'nbidal18-packwiz-sync.next.jar', 'nbidal18-packwiz-updater.next.jar',
    'packwiz-installer.next.jar', 'packwiz-installer-bootstrap.next.jar'
)
$indexed = @(
    Select-String -LiteralPath (Join-Path $site 'index.toml') -Pattern '^file = "(.+)"$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
)
$unlisted = @($mustBeIndexed | Where-Object { $indexed -notcontains $_ })
if ($unlisted.Count) {
    throw ("The update engine would never reach a player; these are served but absent from index.toml: " +
        ($unlisted -join ', ') + ". Build-PackwizSite must stage them before packwiz refresh.")
}
Write-Host ("engine    {0} staged jars, all present in index.toml" -f $mustBeIndexed.Count)

# The live jars are deliberately NOT published. packwiz would overwrite the updater jar that is
# running the sync at that moment; the client ZIP is what supplies them for a first install.
$mustNotBePublished = @('nbidal18-packwiz-sync.jar', 'nbidal18-packwiz-updater.jar')
$leaked = @($mustNotBePublished | Where-Object { Test-Path -LiteralPath (Join-Path $site $_) })
if ($leaked.Count) { throw ("These must not be published: " + ($leaked -join ', ')) }

# The client ZIP must contain everything the supervisor needs before Minecraft ever starts.
# prism/mmc-pack.json is the one that is easy to omit and fails hard: the pre-launch command exits
# 1 and the game never opens. It shipped missing in v1.0.0.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipRequired = @('mmc-pack.json', 'instance.cfg', '.packignore',
    'minecraft/prism/mmc-pack.json',
    'minecraft/nbidal18-packwiz-sync.jar', 'minecraft/nbidal18-packwiz-updater.jar',
    'minecraft/nbidal18-packwiz-sync.next.jar', 'minecraft/nbidal18-packwiz-updater.next.jar',
    'minecraft/packwiz-installer.jar', 'minecraft/packwiz-installer-bootstrap.jar',
    'minecraft/packwiz-installer.next.jar', 'minecraft/packwiz-installer-bootstrap.next.jar')
$zipArchive = [IO.Compression.ZipFile]::OpenRead((Join-Path $site $clientZip))
try { $inZip = @($zipArchive.Entries | ForEach-Object { $_.FullName }) } finally { $zipArchive.Dispose() }
$zipMissing = @($zipRequired | Where-Object { $inZip -notcontains $_ })
if ($zipMissing.Count) { throw ("$clientZip is missing: " + ($zipMissing -join ', ')) }
Write-Host ("clientzip {0} entries, all {1} required present" -f $inZip.Count, $zipRequired.Count)

$total = Get-ChildItem -LiteralPath $site -Recurse -File | Measure-Object -Sum Length
Write-Host ("release   {0} files, {1:N1} MB, all {2} required artefacts present" -f `
        $total.Count, ($total.Sum / 1MB), $required.Count)

# --- the copy a person actually opens ---------------------------------------------------------
# site\ is generated output nobody should be browsing, and the ZIP lives three folders down inside
# it. "1. setup" is where a player - or the owner, six months from now - goes looking. Refreshed
# from the build every time so the two cannot drift.
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$setup = Join-Path (Split-Path -Parent $repo) "$prefix$version\1. setup"
New-Item -ItemType Directory -Path $setup -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $site $clientZip) -Destination $setup -Force

$sha = (Get-FileHash -LiteralPath (Join-Path $setup $clientZip) -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText((Join-Path $setup 'SHA256SUMS.txt'), "$sha  $clientZip`n",
    (New-Object Text.UTF8Encoding($false)))
Write-Host ("setup     1. setup\{1} refreshed, sha256 {0}" -f $sha.Substring(0, 16), $clientZip)
Write-Host "ready to publish"
