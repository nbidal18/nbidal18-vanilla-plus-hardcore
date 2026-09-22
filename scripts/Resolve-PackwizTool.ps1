<#
.SYNOPSIS
    Resolve the packwiz.exe to RUN, which is deliberately not the one the release pins.

.DESCRIPTION
    Two different jobs, kept apart on purpose:

      the PIN   - every release folder carries its own packwiz.exe under
                  `5. modpack source\auto-updater tools\`, so a release can always be rebuilt with
                  the exact tool it was built with. That copy is the source of truth.
      the PATH  - the binary actually executed lives once, at `vanilla_plus\_tools\packwiz.exe`.

    **Why the second exists: Windows Firewall identifies an application by its full path.**
    `packwiz serve`, which Test-LocalSync runs to host the channel on a loopback port, opens a
    listening socket - and packwiz has no flag to bind loopback only, so Windows prompts
    "allow packwiz.exe to access the network?" the first time each path is seen.

    Running the release's own copy meant a NEW path every release, so that prompt appeared on every
    single release, stole the foreground, and alt-tabbed the owner out of whatever he was playing -
    hardcore Minecraft and Rocket League both (reported 2026-09-21, after being tolerated for
    months). By then the machine had **266 packwiz firewall rules**, one pair per release folder
    going back to the 1.21.1 pack, and the number could only grow.

    A folder-wide firewall rule is not possible: Defender Firewall's Program field is one executable
    path, with no wildcard and no directory scope. So the fix is to stop the path from changing.

    The pin still wins: the stable copy is compared by SHA-256 against the release's copy and
    refreshed whenever they differ, so upgrading packwiz in a release still takes effect - it simply
    costs one firewall prompt at that point rather than one per release for ever.

.PARAMETER Release
    The release root, i.e. the folder that contains "5. modpack source".

.EXAMPLE
    . "$PSScriptRoot\Resolve-PackwizTool.ps1"
    $packwiz = Resolve-PackwizTool -Release $release
#>

function Resolve-PackwizTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Release)

    $pinned = Join-Path $Release '5. modpack source\auto-updater tools\packwiz.exe'
    if (-not (Test-Path -LiteralPath $pinned -PathType Leaf)) {
        throw "packwiz.exe not found at $pinned"
    }

    # Beside the release folders and the server mirrors, not inside the git repo: it is a 12 MB
    # binary that is already pinned per release, so committing it would store it twice.
    $packRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $toolsRoot = Join-Path $packRoot '_tools'
    $stable = Join-Path $toolsRoot 'packwiz.exe'

    $pinnedHash = (Get-FileHash -LiteralPath $pinned -Algorithm SHA256).Hash
    $current = if (Test-Path -LiteralPath $stable -PathType Leaf) {
        (Get-FileHash -LiteralPath $stable -Algorithm SHA256).Hash
    }
    else { $null }

    if ($current -ne $pinnedHash) {
        New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
        Copy-Item -LiteralPath $pinned -Destination $stable -Force
        Write-Host "packwiz   stable copy refreshed from the release pin -> $stable"
        Write-Host "packwiz   Windows may ask about the firewall once for this path. It will not ask again."
    }
    return $stable
}
