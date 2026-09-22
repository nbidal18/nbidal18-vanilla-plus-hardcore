<#
    Rebuilds nbidal18-photon_v1.3b.zip from the upstream zip kept in the pack source.

      scripts\Build-Photon.ps1                  build it into the current release

    Owner, 2026-09-21: "include photon as well". Photon has no ore glow to remove - checked in its
    own files - so the only change is the mob hurt flash, made a HURT_FLASH toggle that is off by
    default, in both places Photon draws it.

    The input is Modrinth's own zip, checked against its SHA-512 before anything is read. The work
    is in build_photon.py beside the pack's README.
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

$builder = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Photon\build_photon.py'
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "Missing input: $builder" }

& python $builder $ReleaseRoot
if ($LASTEXITCODE -ne 0) { throw 'build_photon.py failed' }
