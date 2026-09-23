<#
    Cuts the next version: everything between "the last release shipped" and "Build-Release can run".

      scripts\New-Release.ps1                 patch bump, 1.0.10 -> 1.0.11
      scripts\New-Release.ps1 -Version 1.1.0  an explicit version
      scripts\New-Release.ps1 -WhatIf         say what it would do

    This is the part that was done by hand ten times in one day: copy the release folder, bump the
    version in three places, regenerate the integrity helper's source, compile it, package it,
    install it, delete the previous one. Seven steps, every one of which is silent when skipped
    until something much later goes wrong.

    The first-party mods are built by Build-FirstPartyMods.ps1, which this calls. That split exists
    so a mod can be rebuilt inside an existing release: when the compile lived here, changing one
    line of a mixin meant cutting another version or building the jar by hand.

    What it deliberately does NOT do:

      * touch site\ - that is Build-Release's job, and keeping them apart means this can be re-run
      * write a changelog entry - an entry means "this reached players", so it is written at publish
        time and by hand
      * publish anything

    After it: edit what the release changes, then Build-Release.ps1.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Version,
    [string] $InstanceName = 'nbidal18-vanilla-plus-client'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$packRoot = Split-Path -Parent $repo
$versionFile = Join-Path $repo 'PACK-VERSION.txt'
$current = (Get-Content -LiteralPath $versionFile -Raw).Trim()

if (-not $Version) {
    $parts = $current -split '\.'
    if ($parts.Count -ne 3) { throw "Cannot patch-bump a version shaped like '$current'" }
    $Version = '{0}.{1}.{2}' -f $parts[0], $parts[1], ([int] $parts[2] + 1)
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Not a version: $Version" }

$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$from = Join-Path $packRoot "$prefix$current"
$to = Join-Path $packRoot "$prefix$Version"
if (-not (Test-Path -LiteralPath $from)) { throw "No release folder for the current version: $from" }
if (Test-Path -LiteralPath $to) { throw "$to already exists - a published version is never rebuilt" }

Write-Host ("cutting   v{0} -> v{1}" -f $current, $Version)
if (-not $PSCmdlet.ShouldProcess($to, 'copy the release folder and bump every version')) { return }

# Everything past here is undone if any step throws. A half-cut release - a folder that exists with
# the version bumped and no rebuilt helper - is worse than no release: the next run refuses because
# the folder is already there, and the state looks deliberate.
$rollback = {
    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
    [IO.File]::WriteAllText($versionFile, "$current`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host ("rolled back to v{0}; nothing was left half-cut" -f $current)
}
try {

# ---------------------------------------------------------------- copy, and prove the copy
robocopy $from $to /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with $LASTEXITCODE" }
$a = Get-ChildItem -LiteralPath $from -Recurse -File | Measure-Object Length -Sum
$b = Get-ChildItem -LiteralPath $to -Recurse -File | Measure-Object Length -Sum
if ($a.Count -ne $b.Count -or $a.Sum -ne $b.Sum) {
    throw "The copy does not match the source: $($a.Count)/$($a.Sum) vs $($b.Count)/$($b.Sum)"
}
Write-Host ("copied    {0} files, {1} MB" -f $b.Count, [math]::Round($b.Sum / 1MB))

# ---------------------------------------------------------------- the version, in all of its places
[IO.File]::WriteAllText($versionFile, "$Version`n", (New-Object Text.UTF8Encoding($false)))

# Better Compatibility Checker 26.2 reads config\bcc-common.json and nothing else (its Config class
# names that one file; the bcc-common.toml the 1.21.1 build read was carried here by mistake and
# every client and the server showed CHANGE_ME until v1.0.84). The file is kept in BCC's own
# format - LF, two-space indent, no trailing newline - because it is hash-enforced at login and BCC
# only writes it when it is missing, so the published bytes stand. The version is the one field
# that changes here; everything else is left byte for byte.
#
# The server master keeps its own copy under 4. server\config. The deploy takes the client copy, so
# the server never ran a stale one - but the master said v1.0.0 after the v1.0.1 cut (2026-09-24),
# which is a master describing a release that no longer exists. Both move together.
$bccCopies = @((Join-Path $to '3. modpack\client\config\bcc-common.json'),
               (Join-Path $to '4. server\config\bcc-common.json')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($bccCopies.Count -eq 0) { throw 'No bcc-common.json in the release' }
foreach ($bcc in $bccCopies) {
    $text = [IO.File]::ReadAllText($bcc)
    $expected = '"value": "v{0}"' -f $current
    if (([regex]::Matches($text, [regex]::Escape($expected))).Count -ne 1) { throw "$bcc does not say $expected exactly once" }
    [IO.File]::WriteAllText($bcc, $text.Replace($expected, ('"value": "v{0}"' -f $Version)),
        (New-Object Text.UTF8Encoding($false)))
}
Write-Host ("version   PACK-VERSION.txt and {0} bcc-common.json -> {1}" -f $bccCopies.Count, $Version)

# ---------------------------------------------------------------- the first-party mods
# Delegated rather than inlined: a first-party mod has to be rebuildable inside the release you are
# already working in, not only at the moment it is cut. Building it here and nowhere else meant
# editing a mixin cost you either a wasted version number or a jar assembled by hand.
& (Join-Path $PSScriptRoot 'Build-FirstPartyMods.ps1') -ReleaseRoot $to -InstanceName $InstanceName
if ($LASTEXITCODE -ne 0) { throw 'Build-FirstPartyMods failed' }

    Write-Host ''
    Write-Host ("OK        v{0} is cut. Make the release's changes, then run Build-Release.ps1." -f $Version)
}
catch {
    & $rollback
    throw
}
