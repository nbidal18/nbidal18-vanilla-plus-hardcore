<#
    Rebuilds nbidal18-rethinking-voxels_r0.1-beta9.zip from the upstream zip kept in the pack source.

      scripts\Build-RethinkingVoxels.ps1                  build it into the current release

    Owner, 2026-09-21: "CAN U HOTFIX RETHINKING VOXELS INTO THE MODPACK". Rethinking Voxels is built
    on Complementary's code, so it gets the same two changes every shader here carries: glowing ores
    removed as a capability, and the mob hurt flash made a HURT_FLASH toggle that is off by default.

    The input is Modrinth's own zip, checked against its SHA-512 before anything is read. The work
    is in build_rethinking_voxels.py beside the pack's README.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$packVersion = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path (Split-Path -Parent $repo) "$prefix$packVersion" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

$builder = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Rethinking-Voxels\build_rethinking_voxels.py'
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "Missing input: $builder" }

& python $builder $ReleaseRoot
if ($LASTEXITCODE -ne 0) { throw 'build_rethinking_voxels.py failed' }
