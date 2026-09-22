<#
    Builds site/nbidal18-client.zip - the Prism instance a player imports once.

    The ZIP carries no pack content. It carries the instance definition and the packwiz installer,
    and the pre-launch hook pulls everything else from the channel on first launch. That is what
    makes "click Play" the only update step a player ever performs, and why the ZIP does not need
    re-importing when the pack changes.

    The component list mirrors a working 26.2 instance rather than being composed from scratch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$line = Split-Path -Parent $repo
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$loader = (Get-Content -LiteralPath (Join-Path $repo 'LOADER.txt') -Raw).Trim()
$mc = (Get-Content -LiteralPath (Join-Path $repo 'MINECRAFT.txt') -Raw).Trim()
$url = (Get-Content -LiteralPath (Join-Path $repo 'UPDATE-URL.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path $line "$prefix$version"
$tools = Join-Path $release '5. modpack source\auto-updater tools'
$site = Join-Path $repo 'site'
if (-not (Test-Path -LiteralPath $site)) { throw "Run Build-PackwizSite.ps1 first - no site/ at $site" }

$stage = Join-Path ([IO.Path]::GetTempPath()) ("nbidal18-client-" + [Guid]::NewGuid().ToString('N'))
$mcDir = Join-Path $stage 'minecraft'
New-Item -ItemType Directory -Path $mcDir -Force | Out-Null
$enc = New-Object Text.UTF8Encoding($false)
function W($path, $text) { [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), $enc) }

# ---------------------------------------------------------------- instance definition
# 8 GB because this pack ships Voxy: its LOD store and generation threads are the reason the
# launcher default of 4 GB produced multi-second stalls on alt-tab.
W (Join-Path $stage 'instance.cfg') @"
[General]
iconKey=server-icon
name=nbidal18-vanilla-plus
AutomaticJava=true
InstanceType=OneSix
ExportName=nbidal18-vanilla-plus
ExportOptionalFiles=true
ExportSummary=Minecraft $mc vanilla+ modpack with automatic updates
ExportVersion=$version
IgnoreJavaCompatibility=false
JoinServerOnLaunch=false
ManagedPack=false
OverrideJavaLocation=false
OverrideMemory=true
MinMemAlloc=2048
MaxMemAlloc=8192
OverrideCommands=true
PreLaunchCommand="`$INST_JAVA" -jar nbidal18-packwiz-sync.jar
UseAccountForInstance=false
"@

$mmc = @"
{
  "components": [
    {"cachedName":"LWJGL 3","cachedVersion":"3.4.1","cachedVolatile":true,"dependencyOnly":true,"uid":"org.lwjgl3","version":"3.4.1"},
    {"cachedName":"Minecraft","cachedRequires":[{"suggests":"3.4.1","uid":"org.lwjgl3"}],"cachedVersion":"$mc","important":true,"uid":"net.minecraft","version":"$mc"},
    {"cachedName":"Intermediary Mappings","cachedRequires":[{"equals":"$mc","uid":"net.minecraft"}],"cachedVersion":"$mc","cachedVolatile":true,"dependencyOnly":true,"uid":"net.fabricmc.intermediary","version":"$mc"},
    {"cachedName":"Fabric Loader","cachedRequires":[{"uid":"net.fabricmc.intermediary"}],"cachedVersion":"$loader","uid":"net.fabricmc.fabric-loader","version":"$loader"}
  ],
  "formatVersion": 1
}
"@
W (Join-Path $stage 'mmc-pack.json') $mmc

# minecraft\prism\mmc-pack.json is REQUIRED, not optional. The supervisor promotes it over the
# instance's own mmc-pack.json on every launch, and throws if it is missing - which is how a future
# Minecraft or loader bump reaches an instance that was imported once and never re-imported.
# Leaving it out of the ZIP made the pre-launch command exit 1 before Minecraft ever started.
New-Item -ItemType Directory -Path (Join-Path $mcDir 'prism') -Force | Out-Null
W (Join-Path $mcDir 'prism\mmc-pack.json') $mmc

# Player-owned runtime state that must never be swept into an export or an update.
W (Join-Path $stage '.packignore') @"
minecraft/saves
minecraft/screenshots
minecraft/logs
minecraft/crash-reports
minecraft/debug
minecraft/local
minecraft/data
minecraft/voxy
minecraft/server-resource-packs
minecraft/usercache.json
minecraft/command_history.txt
minecraft/.mixin.out
minecraft/.packwiz-cache
"@

# ---------------------------------------------------------------- payload
#
# Prism runs nbidal18-packwiz-sync.jar (the supervisor). It promotes any staged .next.jar and then
# runs the updater, which talks to the channel and drives packwiz-installer.
#
# Every jar ships twice, as .jar and .next.jar. The .next copy is what the supervisor promotes, and
# shipping it in the ZIP means the very first launch already has a complete staging pair rather
# than a half-populated one.
foreach ($j in 'packwiz-installer-bootstrap.jar', 'packwiz-installer.jar') {
    Copy-Item -LiteralPath (Join-Path $tools $j) -Destination $mcDir -Force
    Copy-Item -LiteralPath (Join-Path $tools $j) -Destination (Join-Path $mcDir ($j -replace '\.jar$', '.next.jar')) -Force
}
foreach ($j in 'nbidal18-packwiz-sync.jar', 'nbidal18-packwiz-updater.jar') {
    $built = Join-Path $repo "client\$j"
    if (-not (Test-Path -LiteralPath $built)) { throw "Run Build-Updater.ps1 first - missing $j" }
    Copy-Item -LiteralPath $built -Destination $mcDir -Force
    Copy-Item -LiteralPath $built -Destination (Join-Path $mcDir ($j -replace '\.jar$', '.next.jar')) -Force
}
$icon = Join-Path $tools 'server-icon.png'
if (Test-Path -LiteralPath $icon) { Copy-Item -LiteralPath $icon -Destination $stage -Force }

# Seed options once. Ships the tuned defaults this pack was built around - notably
# inactivityFpsLimit=minimized, which keeps Voxy generating while the window is in the background.
$seedOptions = Join-Path $release '3. modpack\client\options.txt'
if (Test-Path -LiteralPath $seedOptions) { Copy-Item -LiteralPath $seedOptions -Destination $mcDir -Force }

# servers.dat puts the server in the multiplayer list on first launch. It ships HERE and not as
# pack content on purpose: published through the channel, the updater would overwrite the player's
# own server list on every update. Seeded once, then theirs.
$seedServers = Join-Path $release '3. modpack\client\servers.dat'
if (Test-Path -LiteralPath $seedServers) { Copy-Item -LiteralPath $seedServers -Destination $mcDir -Force }

# ---------------------------------------------------------------- pack
$out = Join-Path $site 'nbidal18-client.zip'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression   # ZipArchiveMode lives here, not in .FileSystem

# Built deterministically: entries in sorted order, every timestamp pinned. CreateFromDirectory
# stamps each entry with its file's mtime, so an unchanged shell produced a different ZIP on every
# build - which means the published copy and the local one disagree forever, and any verification
# of the channel against the build reports a difference that is not one.
$epoch = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$zip = [IO.Compression.ZipFile]::Open($out, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -LiteralPath $stage -Recurse -File |
        Sort-Object { $_.FullName.Substring($stage.Length + 1).Replace('\', '/') } |
        ForEach-Object {
            $rel = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $epoch
            $in = [IO.File]::OpenRead($_.FullName)
            try { $es = $entry.Open(); try { $in.CopyTo($es) } finally { $es.Dispose() } }
            finally { $in.Dispose() }
        }
}
finally { $zip.Dispose() }
Remove-Item -LiteralPath $stage -Recurse -Force

$zip = [IO.Compression.ZipFile]::OpenRead($out)
Write-Host ("nbidal18-client.zip  {0} entries, {1:N0} bytes" -f $zip.Entries.Count, (Get-Item -LiteralPath $out).Length)
$zip.Entries | Sort-Object FullName | ForEach-Object { Write-Host ("   {0,-46} {1,9:N0}" -f $_.FullName, $_.Length) }
$zip.Dispose()
