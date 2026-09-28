<#
    Rebuilds the pack's Eclipse shader: the fork with Complementary's IntegratedPBR ported onto it,
    behind a master COMPLEMENTARY_PBR switch.

      scripts\Build-EclipseComplementary.ps1        build it into the current release
      scripts\Build-EclipseComplementary.ps1 -ReleaseRoot <folder>

    Owner, 2026-09-27: "is it possible to duplicate our eclispe, and give it the full complimentary
    reimagined integrated PBR? ... basically i want eclipse views with complimentary textures".

    One shader ships. The input is the pristine fork kept in the port's own upstream folder, and the
    patched result goes into the release under the same file name, so Iris keeps the settings file
    players already have. The block lists come out of the release's own Complementary zip, so the port
    has no outside dependency.

    Before v1.0.15 the port shipped as a second 47 MB zip beside the plain one. Owner, 2026-09-28:
    "make the complimentary stuff be the 'complimentary PBR' toggle" - so the master switch replaced
    it, and saves every player 45 MB.

    Everything the port does, why each piece is in and what was deliberately left out, is in
    5. modpack source\custom packs\nbidal18-Eclipse-Shader\README.md. The one rule worth repeating
    here: it changes nothing about light. The v1.0.104 attempt at this in the Vanilla+ line patched
    Eclipse's light table and forced the block-light level on lanterns, and the owner's verdict was
    that it "broke eclipse lightning which was sort of softly flickering". This build asserts that
    dimensions\setup.csh comes through byte for byte and that the ported code names no lighting
    variable.

    Timestamps and entry order are pinned, so the same inputs rebuild byte-identically and the pack's
    manifest digest does not move when nothing changed.
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

$source = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Eclipse-Shader'
$builder = Join-Path $source 'build_eclipse_complementary.py'
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "Missing input: $builder" }

$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { throw 'No python on PATH; the builder is a Python script.' }

Write-Host ("building  from {0}" -f (Split-Path $source -Leaf))
& $python.Source $builder $ReleaseRoot
if ($LASTEXITCODE -ne 0) { throw "build_eclipse_complementary.py failed with exit code $LASTEXITCODE" }

$out = Join-Path $ReleaseRoot '3. modpack\client\shaderpacks\nbidal18-Eclipse-Shader-Unstable.zip'
if (-not (Test-Path -LiteralPath $out -PathType Leaf)) { throw "The builder wrote no zip at $out" }
Write-Host ("OK        {0} ({1:N0} bytes)" -f (Split-Path $out -Leaf), (Get-Item -LiteralPath $out).Length)
Write-Host '          next: scripts\Build-Release.ps1'
