<#
.SYNOPSIS
    Move a live server's End dimension aside so it regenerates, optionally switching it to BetterX.

.DESCRIPTION
    Written 2026-09-22. The owner asked to reset the End on both servers and re-enter it with the
    void fix in `nbidal18-theend` 1.1.0, killing the dragon by command since it has already been
    beaten once.

    **This destroys player content and cannot be undone by this script.** Everything in the End goes:
    bases, chests, looted cities, and every block any player has placed. On Vanilla+ that is 533
    region files and 2.1 GB of explored terrain. Nothing here decides that this is a good idea; it is
    run only when the owner has said so.

    **The old dimension is renamed, never deleted.** A 2 GB download inside a server outage is not a
    backup anybody would actually wait for, and a delete has no undo at all. `the_end` becomes
    `the_end.<label>` on the server: instant, reversible by moving it back, and the owner can delete
    it himself once satisfied. It does cost that disk until he does.

    **The dragon resets for free.** `ender_dragon_fight.dat` lives in
    `dimensions/minecraft/the_end/data/minecraft/`, inside the folder being moved, so the fight state
    goes with it and the dragon respawns on first entry.

    **-SwitchToBetterX is for the hardcore server only, and only because its End is empty.**
    A world's End generator is fixed by `<world>/data/wover-generator.nbt`, which WorldWeaver reads
    back at every load - not by `level-type`, and not by the world type screen once the world exists.
    Hardcore's world was created by the server, which has no creation screen, so it got vanilla;
    Vanilla+'s was created in a client where BetterX was chosen, then uploaded. Switching hardcore is
    safe **only** because nobody has ever generated a chunk of its End. Its Nether is deliberately
    left alone: that one is generated and full of Incendium biomes, and switching it would leave a
    permanent seam.

.PARAMETER Session
    The WinSCP site name. `Gamehostbros Vanilla+` or `Gamehostbros Vanilla+ Hardcore Paris`.

.PARAMETER ServerHost
.PARAMETER Port
    Checked with a Minecraft Server List Ping before anything is touched. The script refuses to run
    while the server answers - reading a log to decide is what this repo has been burned by, because
    Server Pause makes a live server look dead for hours.

.EXAMPLE
    .\Reset-EndDimension.ps1 -Session 'Gamehostbros Vanilla+' -ServerHost 194.54.88.14 -Port 27107 -Label pre-v1.0.107
    .\Reset-EndDimension.ps1 -Session 'Gamehostbros Vanilla+ Hardcore Paris' -ServerHost 38.103.248.98 -Port 27037 -Label pre-v1.0.107 -SwitchToBetterX
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Session,
    [Parameter(Mandatory)] [string] $ServerHost,
    [Parameter(Mandatory)] [int] $Port,
    [Parameter(Mandatory)] [string] $Label,
    [string] $WorldPath = '/world',
    # Copy the End entry of this world's wover-generator.nbt from a world that already generates
    # Better End biomes. Requires -BetterXSource.
    [switch] $SwitchToBetterX,
    [string] $BetterXSource,
    # Print what would happen and touch nothing.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$mirror = Join-Path $here 'Sync-ServerMirror.ps1'
$stopped = Join-Path $here 'Test-ServerStopped.ps1'
$setgen = Join-Path $here 'Set-EndGenerator.py'
foreach ($needed in $mirror, $stopped, $setgen) {
    if (-not (Test-Path -LiteralPath $needed)) { throw "Missing helper: $needed" }
}

$endPath = "$WorldPath/dimensions/minecraft/the_end"
$movedTo = "$endPath.$Label"

Write-Host ''
Write-Host "server    $ServerHost`:$Port  ($Session)"
Write-Host "move      $endPath"
Write-Host "      ->  $movedTo"
if ($SwitchToBetterX) { Write-Host "generator switching the End to BetterX from $BetterXSource" }
Write-Host ''

# 1. The server must be down, proven by a ping. Never by a log: Server Pause keeps an empty-but-
#    running server silent for hours, and its UTC timestamps read two hours stale against the local
#    clock, which has fooled more than one agent into editing a server that was live.
Write-Host '1/4  confirming the server is stopped'
& $stopped -ServerHost $ServerHost -Port $Port
if ($LASTEXITCODE -ne 0) {
    throw "$ServerHost`:$Port still answers. Stop it from the provider's web panel first - this script cannot, and must not run against a live server."
}
Write-Host '     confirmed down'

# 2. Record what is there, so the move can be checked against something.
Write-Host '2/4  listing the End before the move'
$before = & $mirror -Session $Session -List $endPath 2>&1
$before | Where-Object { $_ -match '^[d-]' } | ForEach-Object { Write-Host "     $_" }

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN   nothing was moved or written'
    return
}

# 3. The move itself.
Write-Host '3/4  moving the dimension aside'
& $mirror -Session $Session -Move $endPath -MoveTo $movedTo
if ($LASTEXITCODE -ne 0) { throw 'The move failed. Nothing else has been touched.' }

# 4. Optionally repoint the End generator, then prove both by reading the server back.
if ($SwitchToBetterX) {
    if (-not $BetterXSource) { throw 'Pass -BetterXSource with -SwitchToBetterX.' }
    if (-not (Test-Path -LiteralPath $BetterXSource)) { throw "No such source file: $BetterXSource" }
    Write-Host '4/4  switching the End generator to BetterX'
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "wover-generator-$Label.nbt"
    $backup = "$scratch.backup"
    & $mirror -Session $Session -Get "$WorldPath/data/wover-generator.nbt" -To $scratch
    if ($LASTEXITCODE -ne 0) { throw 'Could not fetch wover-generator.nbt.' }
    Copy-Item -LiteralPath $scratch -Destination $backup -Force
    Write-Host "     original kept at $backup"
    python $setgen $scratch $BetterXSource
    if ($LASTEXITCODE -ne 0) { throw 'The generator edit failed; nothing was uploaded.' }
    & $mirror -Session $Session -Put $scratch -PutTo "$WorldPath/data/wover-generator.nbt"
    if ($LASTEXITCODE -ne 0) { throw 'The upload failed. The End folder is already moved - restore it or retry.' }
    # Read it back off the server and print what the server now holds, rather than what was sent.
    $confirm = Join-Path ([IO.Path]::GetTempPath()) "wover-generator-$Label.confirm.nbt"
    & $mirror -Session $Session -Get "$WorldPath/data/wover-generator.nbt" -To $confirm
    python $setgen $confirm --show
} else {
    Write-Host '4/4  generator left as it is'
}

Write-Host ''
Write-Host 'verify    reading the server back'
& $mirror -Session $Session -List "$WorldPath/dimensions/minecraft" 2>&1 |
    Where-Object { $_ -match '^[d-]' } | ForEach-Object { Write-Host "     $_" }
Write-Host ''
Write-Host "OK        the End is moved aside as $movedTo and will regenerate on first entry."
Write-Host '          The dragon fight went with it, so the dragon respawns - kill it with'
Write-Host '          /kill @e[type=minecraft:ender_dragon] once you are in.'
Write-Host "          Delete $movedTo yourself when you are happy; nothing here will."
