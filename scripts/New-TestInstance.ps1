<#
.SYNOPSIS
    Clone the pack's Prism instance into a throwaway copy with chosen mods removed, for testing a
    suspicion without cutting a release.

.DESCRIPTION
    Written 2026-09-21 for the far-terrain question: a player in Lebanon joining the owner's LAN world
    over Tailscale lags and times out on this pack but not on a fresh 26.2, with Voxy's own switch
    off. The switch is client-side, so the only way to clear the whole far-terrain stack as a variable
    is to remove its jars - and a release that does that costs four server outages to test two
    clients.

    **Three things in this pack actively undo a hand-modified instance, which is why this is a script
    and not a note.** All three are correct behaviour and none is a bug:

      1. the updater (`nbidal18-packwiz-sync.jar`, run as Prism's pre-launch command) keeps `mods\`
         exact-match managed, so a jar deleted by hand is back before the game starts;
      2. the integrity helper (`nbidal18-integrity-*.jar`) verifies the published manifest and the
         instance layout and refuses before the main menu when they do not match - this is the
         "anticheat", and a modified instance is exactly what it exists to stop;
      3. Prism's own instance.cfg carries the pre-launch command, so copying the folder copies it too.

    So the copy has the named jars removed, the integrity helper removed, and the pre-launch command
    cleared. **The real instance is never touched**, and this copy can never join the live servers -
    the helper is gone and the server would refuse it anyway. It is for a LAN world only.

    Caches are deliberately not copied: `.voxy` alone runs to gigabytes, and this exists to test
    without it.

.PARAMETER RemoveMods
    Jar name patterns to delete from the copy. Defaults to the whole far-terrain stack - all four go
    together, because the two first-party forks hard-depend on the upstream pair and mixin into them.

.PARAMETER Name
    The new instance's folder name. Defaults to <source>-test.

.PARAMETER KeepIntegrity
    Leave the integrity helper in place. Only useful if you are testing the helper itself; the copy
    will then refuse to reach the main menu.

.EXAMPLE
    .\New-TestInstance.ps1
    .\New-TestInstance.ps1 -Name nbidal18-novoxy
    .\New-TestInstance.ps1 -RemoveMods 'sodium-*.jar'
#>
[CmdletBinding()]
param(
    [string] $SourceInstance = 'nbidal18-vanilla-plus-client',
    [string] $Name,
    [string[]] $RemoveMods = @(
        'voxy-*.jar',
        'Voxy World Gen V2-*.jar',
        'nbidal18-voxy-*.jar',
        'nbidal18-voxyworldgen-*.jar'
    ),
    [switch] $KeepIntegrity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$prismRoot = Join-Path $env:APPDATA 'PrismLauncher'
$source = Join-Path $prismRoot "instances\$SourceInstance"
if (-not (Test-Path -LiteralPath $source)) { throw "No such instance: $source" }
if (-not $Name) { $Name = "$SourceInstance-test" }
$target = Join-Path $prismRoot "instances\$Name"
if (Test-Path -LiteralPath $target) {
    throw "$target already exists. Delete it in Prism first, or pass another -Name."
}

Write-Host ("cloning   {0} -> {1}" -f $SourceInstance, $Name)
# /XD: caches and logs. .voxy is the big one - gigabytes of far terrain this test exists without.
$excluded = @('.voxy', 'logs', 'crash-reports', 'screenshots', '.mixin.out', '.packwiz-cache')
& robocopy $source $target /E /NFL /NDL /NJH /NJS /NP /XD @excluded | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with $LASTEXITCODE" }

$mods = Join-Path $target 'minecraft\mods'
if (-not (Test-Path -LiteralPath $mods)) { throw "The copy has no mods folder: $mods" }

$patterns = @($RemoveMods)
if (-not $KeepIntegrity) { $patterns += 'nbidal18-integrity-*.jar' }

$removed = 0
foreach ($pattern in $patterns) {
    $hits = @(Get-ChildItem -LiteralPath $mods -Filter $pattern -File)
    if (-not $hits) { Write-Warning ("nothing matched {0}" -f $pattern); continue }
    foreach ($jar in $hits) {
        [IO.File]::Delete($jar.FullName)
        Write-Host ("removed   {0}" -f $jar.Name)
        $removed++
    }
}

# The pre-launch command is the updater. Left in place it restores every jar deleted above, silently,
# before the game starts - which looks exactly like the test not working.
$cfgPath = Join-Path $target 'instance.cfg'
$kept = [Collections.Generic.List[string]]::new()
foreach ($line in [IO.File]::ReadAllLines($cfgPath)) {
    if ($line -match '^(PreLaunchCommand|PostExitCommand|WrapperCommand)=') { continue }
    if ($line -match '^OverrideCommands=') { $kept.Add('OverrideCommands=false'); continue }
    if ($line -match '^name=') { $kept.Add("name=$Name"); continue }
    $kept.Add($line)
}
[IO.File]::WriteAllText($cfgPath, ($kept -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("OK        {0} created, {1} jar(s) removed, updater disabled" -f $Name, $removed) -ForegroundColor Green
Write-Host '          The real instance is untouched.'
Write-Host '          This copy CANNOT join the live servers - the integrity helper is gone and the'
Write-Host '          server would refuse it. Open a world and share it to LAN instead.'
Write-Host ''
Write-Host '          Both machines must run this with the SAME -RemoveMods, or the mod lists differ'
Write-Host '          and the join fails for a reason that has nothing to do with what is being tested.'

# robocopy returns 1 for "files were copied", which is success. Without this the script exits 1 and
# every caller reports a failure that did not happen.
exit 0
