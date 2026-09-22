<#
.SYNOPSIS
    The prefix this repository's release folders carry - `v.` for Vanilla+, `hc.` for Hardcore.

.DESCRIPTION
    Written 2026-09-22, splitting the two servers into two packs. Before it, twenty-two scripts each
    built their release path with a hardcoded `v.` prefix, and a second pack would have meant
    twenty-two edited copies of them - two divergent sets of thirty-eight scripts, maintained
    forever, which is the shape `nbidal18-client-tweaks` already regrets.

    **The point is that the script FILES stay identical between the two repositories.** Only
    `RELEASE-PREFIX.txt` differs, so a fix made to a build script here can be copied across verbatim
    instead of being applied twice and drifting.

    Resolved from this script's own location rather than from a caller's variable, because the
    twenty-two call sites do not agree on what they call the repository root - `$repo`, `$packRoot`
    and `$line` all appear. Asking the file system removes that from the caller entirely.

.EXAMPLE
    $prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
    $release = Join-Path (Split-Path -Parent $repo) ($prefix + $version)
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$file = Join-Path $repoRoot 'RELEASE-PREFIX.txt'
if (-not (Test-Path -LiteralPath $file)) {
    throw "No RELEASE-PREFIX.txt beside the scripts ($file). It holds this pack line's release-folder prefix, 'v.' or 'hc.'."
}

$prefix = (Get-Content -LiteralPath $file -Raw).Trim()
if (-not $prefix) {
    throw "RELEASE-PREFIX.txt is empty. It must hold this pack line's release-folder prefix, 'v.' or 'hc.'."
}
# A prefix that lost its separator would resolve "1.0.109" as a sibling of the repository rather than
# a release folder, and every script would then fail somewhere further along with a confusing path.
if (-not $prefix.EndsWith('.')) {
    throw "RELEASE-PREFIX.txt is '$prefix'; it must end with a dot, as in 'v.' or 'hc.'."
}

$prefix
