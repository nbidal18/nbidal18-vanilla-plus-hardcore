<#
    Rebuilds nbidal18-3D-1.3.zip: the one 3D resource pack this modpack maintains.

      scripts\Build-3DPack.ps1               build it into the current release
      scripts\Build-3DPack.ps1 -CheckOnly    re-measure the pack already in the release

    Until v1.0.62 the 3D look came from four separately maintained packs - Actually 3D (a fork built
    by Build-Actually3D.ps1), Weskerson's 3D Items (Build-Weskersons3DItems.ps1), Weskerson's 3D Food
    (the raw upstream) and Weskerson's Torches (patch_torches.py) - stacked in a fixed order and each
    with its own idea of which contexts an item is 3D in. Beds were 3D in the inventory, tools were
    fake-3D sprites everywhere, Weskerson's food lay flat on the ground and in item frames, and the
    inventory look of 254 items differed from vanilla's without anyone having decided that.

    The owner's rule, 2026-09-03: **3D in the hand and in the world; exactly vanilla in any
    inventory.** One pack now carries all four sources and enforces that rule by measurement over
    every item definition in the game, through the real pack order from options.txt. The work is in
    `build_3d_pack.py` beside the sources; this script only finds the inputs and runs it. Read the
    docstring there before changing anything.

    None of the artwork is ours. SOURCES.md inside the pack says where every asset came from; the
    pack is for this modpack's own channel and is not published anywhere else.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot,
    [switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$packVersion = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path (Split-Path -Parent $repo) "$prefix$packVersion" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

$builder = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-3D\build_3d_pack.py'
$options = Join-Path $ReleaseRoot '3. modpack\client\options.txt'
$mcJar = Join-Path $env:APPDATA 'PrismLauncher\libraries\com\mojang\minecraft\26.2\minecraft-26.2-client.jar'
foreach ($required in @($builder, $options, $mcJar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing input: $required" }
}

$args = @($ReleaseRoot, $mcJar, $options)
if ($CheckOnly) { $args += '--check-only' }
& python $builder @args
if ($LASTEXITCODE -ne 0) { throw 'build_3d_pack.py failed - read its output above' }

if (-not $CheckOnly) {
    Write-Host ''
    Write-Host 'OK        run Build-Release.ps1 to fold this into the pack.'
}
