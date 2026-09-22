<#
    Builds site/ from the release folder's client master.

    The version is read from PACK-VERSION.txt and nowhere else. The release folder name must agree
    with it, and the build stops if it does not - that mismatch is what published a client whose own
    integrity check rejected its own manifest in the 1.21.1 pack.

    Every published file under config/ must carry a ruling in config-classification.json. The build
    stops while any is unclassified, so adding a mod forces a deliberate decision rather than
    silently inheriting hash enforcement.
#>
[CmdletBinding()]
param(
    [switch] $SkipInstallerJars,
    # A player-class file whose published bytes may change this release. Changing them re-delivers
    # the file to every instance - packwiz downloads whatever hash moved, and "preserved" only holds
    # while the published copy stands still - which wipes the player's own edits. v1.0.74 did that
    # to every player's Eclipse shader settings by editing the master to carry the new cloud heights
    # the seed already carried. So the build refuses unless the path is named here on purpose.
    [string[]] $RedeliverPlayerFile = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$line = Join-Path (Split-Path -Parent $repo) ''      # ...\vanilla_plus\
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "PACK-VERSION.txt is not a version: '$version'" }

$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path $line "$prefix$version"
if (-not (Test-Path -LiteralPath $release)) {
    throw "PACK-VERSION.txt says $version but there is no release folder at $release"
}
$client = Join-Path $release '3. modpack\client'
if (-not (Test-Path -LiteralPath $client)) { throw "No client master at $client" }

Write-Host "version   $version"
Write-Host "release   $release"

# ---------------------------------------------------------------- classification gate
$classPath = Join-Path $PSScriptRoot 'config-classification.json'
# Explicit UTF-8. Get-Content in Windows PowerShell 5.1 decodes as the system ANSI codepage, so a
# path containing a section sign came back as two characters - the UTF-8 bytes read one at a time.
# That put a mojibake path into localAllowed, which the updater matches exactly, so the E-LITE
# shader settings file was never recognised as player-owned: it was enforced instead, and any player
# who changed a shader option would have been refused at login. Found by Test-LocalSync.
$class = [IO.File]::ReadAllText($classPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$rules = @{}
foreach ($r in $class.rules) { $rules[$r.match] = $r.class }

function Get-Ruling([string] $relPath) {
    $best = $null; $bestLen = -1
    foreach ($m in $rules.Keys) {
        $hit = if ($m.EndsWith('/')) { $relPath.StartsWith($m) } else { $relPath -eq $m }
        if ($hit -and $m.Length -gt $bestLen) { $best = $rules[$m]; $bestLen = $m.Length }
    }
    return $best
}

$configRoot = Join-Path $client 'config'
$unclassified = @()
if (Test-Path -LiteralPath $configRoot) {
    Get-ChildItem -LiteralPath $configRoot -Recurse -File | ForEach-Object {
        $rel = 'config/' + $_.FullName.Substring($configRoot.Length + 1).Replace('\', '/')
        if (-not (Get-Ruling $rel)) { $unclassified += $rel }
    }
}
if ($unclassified.Count) {
    throw ("{0} published config files are unclassified. Add a ruling for each in {1}:`n  {2}" -f `
            $unclassified.Count, $classPath, ($unclassified -join "`n  "))
}
Write-Host ("config    {0} files, all classified" -f $rules.Count)

# ---------------------------------------------------------------- stage
$site = Join-Path $repo 'site'
if (Test-Path -LiteralPath $site) { Remove-Item -LiteralPath $site -Recurse -Force }
New-Item -ItemType Directory -Path $site -Force | Out-Null

foreach ($root in 'mods', 'config', 'shaderpacks', 'resourcepacks', 'datapacks') {
    $src = Join-Path $client $root
    if (-not (Test-Path -LiteralPath $src)) { continue }
    robocopy $src (Join-Path $site $root) /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $root (exit $LASTEXITCODE)" }
}
foreach ($f in 'THIRD-PARTY-NOTICES.md', 'credits.txt') {
    $p = Join-Path $client $f
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $site -Force }
}

# ---------------------------------------------------------------- staged tools
#
# The four .next.jar files are staged HERE, before packwiz refresh, because that is the only way
# they reach a player: packwiz downloads what the index lists, and the supervisor then promotes
# what packwiz put in the instance. Nothing else fetches them.
#
# They used to be written by Build-Updater, which runs after this script - so they were served on
# the channel and listed in nothing. Every instance therefore kept whatever update engine its
# client ZIP shipped, for ever, and the self-update path was inert from v1.0.0 to v1.0.2. It went
# unnoticed because the release gate checked that they existed in site\, which they did.
#
# Only the .next copies are indexed. Indexing the live nbidal18-packwiz-updater.jar would have
# packwiz overwrite the jar that is running the sync at that moment.
$stagedTools = [ordered]@{
    'nbidal18-packwiz-sync.next.jar'       = Join-Path $repo 'client\nbidal18-packwiz-sync.jar'
    'nbidal18-packwiz-updater.next.jar'    = Join-Path $repo 'client\nbidal18-packwiz-updater.jar'
    'packwiz-installer-bootstrap.next.jar' = Join-Path $release '5. modpack source\auto-updater tools\packwiz-installer-bootstrap.jar'
    'packwiz-installer.next.jar'           = Join-Path $release '5. modpack source\auto-updater tools\packwiz-installer.jar'
}
foreach ($staged in $stagedTools.Keys) {
    $source = $stagedTools[$staged]
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Run Build-Updater.ps1 first - missing $source, so $staged cannot be staged and would never reach a player"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $site $staged) -Force
}
Write-Host ("staged    {0} update-engine jars, before the index so packwiz delivers them" -f $stagedTools.Count)

# prism\mmc-pack.json is published as pack content so the channel can change the Minecraft or
# loader version of an instance that was imported once. The updater downloads it like any other
# managed file; the supervisor promotes it on the next launch. Written from the same single source
# as the client shell - LOADER.txt and MINECRAFT.txt - so the two cannot disagree.
$loaderVer = (Get-Content -LiteralPath (Join-Path $repo 'LOADER.txt') -Raw).Trim()
$mcVer = (Get-Content -LiteralPath (Join-Path $repo 'MINECRAFT.txt') -Raw).Trim()
New-Item -ItemType Directory -Path (Join-Path $site 'prism') -Force | Out-Null
$mmcJson = @"
{
  "components": [
    {"cachedName":"LWJGL 3","cachedVersion":"3.4.1","cachedVolatile":true,"dependencyOnly":true,"uid":"org.lwjgl3","version":"3.4.1"},
    {"cachedName":"Minecraft","cachedRequires":[{"suggests":"3.4.1","uid":"org.lwjgl3"}],"cachedVersion":"$mcVer","important":true,"uid":"net.minecraft","version":"$mcVer"},
    {"cachedName":"Intermediary Mappings","cachedRequires":[{"equals":"$mcVer","uid":"net.minecraft"}],"cachedVersion":"$mcVer","cachedVolatile":true,"dependencyOnly":true,"uid":"net.fabricmc.intermediary","version":"$mcVer"},
    {"cachedName":"Fabric Loader","cachedRequires":[{"uid":"net.fabricmc.intermediary"}],"cachedVersion":"$loaderVer","uid":"net.fabricmc.fabric-loader","version":"$loaderVer"}
  ],
  "formatVersion": 1
}
"@
[IO.File]::WriteAllText((Join-Path $site 'prism\mmc-pack.json'), ($mmcJson -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- pack.toml
$loader = (Get-Content -LiteralPath (Join-Path $repo 'LOADER.txt') -Raw).Trim()
$mc = (Get-Content -LiteralPath (Join-Path $repo 'MINECRAFT.txt') -Raw).Trim()
# From a file for the same reason as RELEASE-PREFIX.txt: this script is byte-identical in the
# Vanilla+ and Hardcore repositories, and a pack name baked in here would have been the one thing
# forcing them apart. It is what a player sees as the pack's name in Prism.
$packName = (Get-Content -LiteralPath (Join-Path $repo 'PACK-NAME.txt') -Raw).Trim()
$packToml = @"
name = "$packName"
version = "$version"
description = "Minecraft $mc vanilla+ modpack with automatic Prism updates"
pack-format = "packwiz:1.1.0"

[index]
file = "index.toml"
hash-format = "sha256"
hash = ""

[versions]
fabric = "$loader"
minecraft = "$mc"
"@
[IO.File]::WriteAllText((Join-Path $site 'pack.toml'), ($packToml -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- index
# packwiz refresh reads an existing index before rewriting it, so seed an empty one.
[IO.File]::WriteAllText((Join-Path $site 'index.toml'), "hash-format = `"sha256`"`n", (New-Object Text.UTF8Encoding($false)))

# Pinned per release, run from one stable path - Resolve-PackwizTool.ps1 explains why at length.
. (Join-Path $PSScriptRoot 'Resolve-PackwizTool.ps1')
$packwiz = Resolve-PackwizTool -Release $release
Push-Location $site
try {
    & $packwiz refresh 2>&1 | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -Last 3 | ForEach-Object { Write-Host "packwiz   $_" }
    if ($LASTEXITCODE -ne 0) { throw "packwiz refresh failed (exit $LASTEXITCODE)" }
}
finally { Pop-Location }

$entriesList = @(
    Select-String -LiteralPath (Join-Path $site 'index.toml') -Pattern '^file = "(.+)"$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
)
$entries = $entriesList.Count
if ($entries -eq 0) { throw 'packwiz produced an index with no file entries.' }
$indexHash = (Get-FileHash -LiteralPath (Join-Path $site 'index.toml') -Algorithm SHA256).Hash.ToLower()
Write-Host ("index     {0} files, sha256 {1}" -f $entries, $indexHash.Substring(0, 16))

# ---------------------------------------------------------------- sync manifest
#
# What the pre-launch updater and (later) the integrity helper read. The packwiz index says what
# the files are; this says how each one may be treated.
function Get-NormalizedTextSha256([string] $path) {
    # A second hash with line endings normalised. Windows, macOS and Linux clients otherwise
    # disagree about the same config file, which is a false alarm rather than tampering.
    $text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

$playerPaths = @($class.rules | Where-Object { $_.class -eq 'player' } | ForEach-Object { $_.match })
$supportPaths = @($class.rules | Where-Object { $_.class -eq 'support' } | ForEach-Object { $_.match })
foreach ($o in $class.outsideConfig) {
    if ($o.class -eq 'player') { $playerPaths += $o.match }
}

# Never overwritten once installed: genuinely player-owned files, plus the SUPPORT files their own
# mod rewrites at startup. Gameplay files are deliberately not preserved even when they rewrite -
# measurement showed those rewrites are byte-identical, so updating them costs nothing and a
# preserved gameplay file could never be corrected by a release.
$supportLookup = @{}
foreach ($s in $supportPaths) { $supportLookup[$s] = $true }
$preserved = @($playerPaths) + @($class.rewrittenAtRuntime | Where-Object { $supportLookup.ContainsKey($_) })

$manifestFiles = [Collections.Generic.List[object]]::new()
$normalizedTextFiles = [Collections.Generic.List[object]]::new()
foreach ($entry in $entriesList) {
    $full = Join-Path $site ($entry -replace '/', '\')
    $manifestFiles.Add([ordered]@{ path = $entry; sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower() })
    if ($entry -like 'config/*') {
        $normalizedTextFiles.Add([ordered]@{ path = $entry; sha256 = Get-NormalizedTextSha256 $full })
    }
}

# ---------------------------------------------------------------- player files must stand still
#
# The last published manifest is the committed one - one publish per commit - so it is read from
# git rather than from site\, which this script has already wiped. A preserved file whose bytes
# moved is about to be re-delivered on top of every player's copy; the only legitimate way to
# change one of these on existing instances is a seed, which writes the rows it names and nothing
# else. A file that is new to the pack is delivered once by design and is not a change.
#
# The `2>$null` below is not enough on its own. Under $ErrorActionPreference = 'Stop', anything a
# native executable writes to stderr is raised as a NativeCommandError and terminates the script
# before the guard on the next line can run. git writes to stderr in both of the cases this lookup
# exists to tolerate - a repository with no commits, and a first build whose HEAD has no
# site/sync-manifest.json - so the preference is relaxed across the call and restored immediately.
# Found 2026-09-22 on the hardcore pack's first build; Vanilla+ never hit it because it has always
# had a previous manifest to read.
$repo = Split-Path -Parent $PSScriptRoot
$previousJson = $null
$savedErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $previousJson = & git -C $repo show HEAD:site/sync-manifest.json 2>$null }
catch { $previousJson = $null }
finally { $ErrorActionPreference = $savedErrorAction }
if ($LASTEXITCODE -eq 0 -and $previousJson) {
    $previous = @{}
    foreach ($entry in (($previousJson -join "`n") | ConvertFrom-Json).files) { $previous[$entry.path] = $entry.sha256 }
    $preservedLookup = @{}
    foreach ($p in $preserved) { $preservedLookup[$p] = $true }
    $redelivered = @()
    foreach ($entry in $manifestFiles) {
        if (-not $preservedLookup.ContainsKey($entry.path)) { continue }
        if (-not $previous.ContainsKey($entry.path)) { continue }
        if ($previous[$entry.path] -ne $entry.sha256 -and $RedeliverPlayerFile -notcontains $entry.path) {
            $redelivered += $entry.path
        }
    }
    if ($redelivered.Count) {
        throw ("These player-class files changed since the last publish and would be re-delivered over every " +
            "player's own copy: " + ($redelivered -join ', ') + ". Restore the master, and seed the rows that " +
            "must change; or, if replacing every player's file is the intent, pass -RedeliverPlayerFile for each.")
    }
}
else {
    Write-Host 'preserve  no committed manifest to compare against; player-file re-delivery not checked'
}

$manifest = [ordered]@{
    schema              = 1
    packVersion         = $version
    exactRoots          = @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')
    extraTolerantRoots  = @($class.extraTolerantRoots | ForEach-Object { $_.prefix })
    runtimeMutableRoots = @($playerPaths + $supportPaths)
    localAllowed        = @($preserved)
    propertyRules       = @($class.propertyRules | ForEach-Object { [ordered]@{ path = $_.path; key = $_.key; value = $_.value } })
    normalizedTextFiles = @($normalizedTextFiles)
    files               = @($manifestFiles)
}
if ($manifest.extraTolerantRoots.Count -eq 0) { throw 'The classification defines no extra-tolerant roots.' }
if ($manifest.propertyRules.Count -eq 0) { throw 'The classification defines no property rules; the ore pins would be lost.' }

[IO.File]::WriteAllText((Join-Path $site 'sync-manifest.json'),
    (($manifest | ConvertTo-Json -Depth 6) + "`n"), (New-Object Text.UTF8Encoding($false)))
$manifestDigest = (Get-FileHash -LiteralPath (Join-Path $site 'sync-manifest.json') -Algorithm SHA256).Hash.ToLower()
Write-Host ("manifest  {0} files, {1} preserved, {2} pinned keys" -f `
        $manifestFiles.Count, $preserved.Count, $manifest.propertyRules.Count)
Write-Host ("digest    {0}" -f $manifestDigest)

# The server policy the integrity helper reads, written by the build and never by hand. A version
# or digest typed by a person is precisely what locked every player out of the 1.21.1 pack on
# 2026-08-18: the helper's constant said 4.1.3 after the cut, so it refused to parse its own
# manifest. There is deliberately no accepted-digest list - only the current release may join, and
# a client behind is told to close and reopen its game, which is what runs the updater.
$policy = @"
# Generated by Build-PackwizSite for pack version $version. Do not edit by hand.
# Deploy to the server's config\ directory. The helper re-reads it on every login, so a
# false-positive hotfix needs only this file replaced and a client restart.
require-helper=true
expected-manifest-sha256=$manifestDigest
"@
$policyOut = Join-Path $release '4. server\nbidal18-integrity.properties'
New-Item -ItemType Directory -Path (Split-Path -Parent $policyOut) -Force | Out-Null
[IO.File]::WriteAllText($policyOut, ($policy -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host ("policy    4. server\nbidal18-integrity.properties written")

# ---------------------------------------------------------------- checksums
$sums = New-Object Text.StringBuilder
Get-ChildItem -LiteralPath $site -Recurse -File | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($site.Length + 1).Replace('\', '/')
    if ($rel -eq 'SHA256SUMS.txt') { return }
    $null = $sums.AppendFormat("{0}  {1}`n", (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel)
}
[IO.File]::WriteAllText((Join-Path $site 'SHA256SUMS.txt'), $sums.ToString(), (New-Object Text.UTF8Encoding($false)))

$total = (Get-ChildItem -LiteralPath $site -Recurse -File | Measure-Object -Sum Length)
Write-Host ("site      {0} files, {1:N1} MB" -f $total.Count, ($total.Sum / 1MB))
Write-Host "done"
