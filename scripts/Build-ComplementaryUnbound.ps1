<#
    Rebuilds nbidal18-ComplementaryUnbound_r5.9.3.zip: Complementary Unbound with glowing ores removed
    and the mob hurt flash made a toggle, off by default.

      scripts\Build-ComplementaryUnbound.ps1          build it into the current release

    Owner, 2026-09-15: "complimentary unbound shaders with glowing ores enforced off", and "make sure it
    has a flashing mobs setting and turn it off, not enforced off tho". The same two changes the pack's
    Eclipse and E-LITE copies carry.

    The upstream zip, checked against Modrinth's published SHA-512, sits in the pack's source folder;
    the work is in build_complementary.py beside its README. This script only finds them and runs it.
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

$builder = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Complementary-Unbound\build_complementary.py'
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "Missing input: $builder" }

& python $builder $ReleaseRoot
if ($LASTEXITCODE -ne 0) { throw 'build_complementary.py failed' }
