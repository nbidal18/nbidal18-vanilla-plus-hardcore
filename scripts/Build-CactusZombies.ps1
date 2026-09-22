<#
    Rebuilds nbidal18-Cactus-Zombies-1.0.zip: zombies render as cactuses.

      scripts\Build-CactusZombies.ps1                          build it into the current release
      scripts\Build-CactusZombies.ps1 -PreviewDir <folder>     also write a preview image there

    Owner, 2026-09-13: "make zombies render as cactuses. with arms, and a scary look to them" - a joke
    on a friend who grew up thinking zombies were green because they were cactuses.

    Every texture is generated from vanilla's own zombie skins in the client jar, so nothing is drawn
    by hand and a changed layout fails the build instead of shipping a scrambled zombie. The work is
    in build_cactus_zombies.py beside the pack's README; this script only finds the inputs and runs it.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot,
    [string] $PreviewDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$packVersion = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path (Split-Path -Parent $repo) "$prefix$packVersion" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

$builder = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Cactus-Zombies\build_cactus_zombies.py'
$mcJar = Join-Path $env:APPDATA 'PrismLauncher\libraries\com\mojang\minecraft\26.2\minecraft-26.2-client.jar'
foreach ($required in @($builder, $mcJar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing input: $required" }
}

$arguments = @($ReleaseRoot, $mcJar)
if ($PreviewDir) { $arguments += $PreviewDir }
& python $builder @arguments
if ($LASTEXITCODE -ne 0) { throw 'build_cactus_zombies.py failed' }
