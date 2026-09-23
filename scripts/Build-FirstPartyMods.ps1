<#
    Compiles and packages every first-party mod into the current release.

      scripts\Build-FirstPartyMods.ps1                       all of them
      scripts\Build-FirstPartyMods.ps1 -Only nbidal18-invmov just that one

    This used to live inside New-Release, which meant a first-party mod could only be rebuilt by
    cutting a version. Editing one line of a mixin and getting it into the release you are already
    working in was impossible - the workaround was to cut another release, which burns a version
    number for nothing, or to build the jar by hand, which is how stale jars get shipped.

    The classpath is built from Prism's own metadata plus the mods the release is about to ship, so
    a first-party mod compiles against what it will run beside rather than against whatever is
    installed on this machine today. Fabric API's ~190 nested jars are expanded one level, because
    javac cannot see into a jar-in-jar and every fabric.api import would otherwise fail.

    Each mod is a folder under `5. modpack source\custom mods\` with `src\*.java` and a Python
    builder that takes the compiled-classes directory and writes the jar. A mod may also have a
    generator that runs first - the integrity helper's source is generated from the pack version.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot,
    [string] $InstanceName = 'nbidal18-vanilla-plus-client',
    [string[]] $Only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path (Split-Path -Parent $repo) "$prefix$version" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

# Each entry: folder name, optional generator, builder. Order matters only in that the integrity
# helper is the one that can lock players out, so it is built first and fails loudest.
$mods = @(
    # Nine entries were removed here on 2026-09-23, with their source folders: Better End,
    # Farmer's Delight, Carry On, Traveler's Backpack, Reliable Gliders, Incendium, Better Fishing,
    # Mouse Wheelie and Almanac. This line does not ship those mods, so it has nothing to customise
    # for them - and leaving them listed was not harmless: a full run of this script would have
    # compiled nine jars for removed mods straight into "3. modpack\client\mods", and the next
    # Build-PackwizSite would have published them. All nine are still maintained on the Vanilla+
    # line, which does ship them.
    @{ Name = 'nbidal18-integrity'; Generator = 'port_integrity.py'; Builder = 'build_integrity.py' },
    @{ Name = 'nbidal18-invmov'; Generator = $null; Builder = 'build_invmov.py' },
    # Left in v1.0.72 when the world went back to normal survival; back in v1.0.87 for the second,
    # hardcore world, gated (HardcoreGate + a `return 0` at the head of both tick functions) so it
    # is dormant on the normal-survival world. Datapack in a jar plus three classes. **Runs on the
    # server** - needs -AddMods.
    @{ Name = 'nbidal18-hardcorerevive'; Generator = $null; Builder = 'patch_hcrplus.py' },
    # Blank graves (v1.0.89): one client mixin cancelling Gravestones' text rendering, because the
    # mod has no setting for it - only the date's format. Client only.
    @{ Name = 'nbidal18-gravestones'; Generator = $null; Builder = 'build_gravestones.py' },
    # Both Xaero artefacts run on the server too since v1.0.87 (1.1.0): each sends the map its own
    # level-id packet so that two worlds behind one address keep separate maps and waypoints.
    # Needs -AddMods.
    @{ Name = 'nbidal18-xaerominimap'; Generator = $null; Builder = 'build_xaerominimap.py' },
    @{ Name = 'nbidal18-xaeroworldmap'; Generator = $null; Builder = 'build_xaeroworldmap.py' },
    # Neutralises BOTH PostHog clients this mod ships - its own, and the one inside the bundled
    # meza_core library. meza's is the one that mattered: PostHog's sender thread is non-daemon, so
    # the JVM could not exit and Minecraft's watchdog halted it 15 seconds later, which is a
    # non-zero exit and why Prism opened its console on every quit. A thread dump names the culprit
    # in one line; two releases were spent guessing before anyone took one. Drop this fork the
    # moment upstream calls its own Telemetry.shutdown().
    @{ Name = 'nbidal18-soundsbegone'; Generator = $null; Builder = 'build_soundsbegone.py' },
    # skin_overrides schedules three fixed-rate tasks on a pool with no thread factory, so its
    # threads are non-daemon: the JVM could not exit and the watchdog halted it 15 seconds later.
    # Its own cleanup hangs off Util.shutdownExecutors(), which 26.2 no longer reaches on that path,
    # so this makes the threads daemon instead - correct whenever cleanup runs, or does not.
    @{ Name = 'nbidal18-skinoverrides'; Generator = $null; Builder = 'build_skinoverrides.py' },
    # Immersive Paintings' ClientPaintingManager and its painting screen each build a fixed thread
    # pool in <clinit> with no factory and never shut it down. Third of the threads that kept the
    # client from exiting (2026-09-05 thread dump: pool-12-thread-1/2). Daemon factory instead.
    @{ Name = 'nbidal18-immersivepaintings'; Generator = $null; Builder = 'build_immersivepaintings.py' },
    # Realistic Death Visuals: the death screen as a flash, ten seconds of black, respawn and a
    # fade. Upstream stops at 1.21.11 and published no source; this is the pack's own Apache-2.0
    # reconstruction, carried from 4.5.2 and ported to 26.2's screen API. Client only.
    @{ Name = 'nbidal18-realisticdeathvisuals'; Generator = $null; Builder = 'build_realisticdeathvisuals.py' },
    # Records are heard at full volume to ten blocks and not at all from twenty-six, vanilla discs
    # and VinURL's alike, instead of vanilla's 64-block reach. A second consumer on the sound
    # channel sets OpenAL's reference and max distance after vanilla's own. Client only.
    @{ Name = 'nbidal18-jukebox'; Generator = $null; Builder = 'build_jukebox.py' },
    # Sound Physics muffles a sound by its single least-blocked ray, so one gap among nine means no
    # muffling and a record on the floor above jumps between "clear" and "through the floor" from
    # one step to the next. Blends the nine rays by the energy they let through. Client only.
    @{ Name = 'nbidal18-soundphysics'; Generator = $null; Builder = 'build_soundphysics.py' },
    # Ctrl+Alt+W holds the forward key down until the back key cancels it. First-party content
    # rather than a fork - it patches nothing, so it has no target to be named for. It holds the
    # key and not the movement input, which is what makes it work for boats, horses and Immersive
    # Aircraft rather than only for walking.
    @{ Name = 'nbidal18-autopilot'; Generator = $null; Builder = 'build_autopilot.py' },
    # Paces Voxy World Gen's far-terrain stream to what each player's connection and client can
    # take - bytes in flight under a window steered by measured queueing delay, acknowledged by the
    # client every tick - and delivers everything it holds back, loading a chunk from disk when it
    # has unloaded. That last part is what the v1.0.48-55 attempts lacked and why their hold-backs
    # left a ring of missing terrain. Also the client-side ledger, the resync of dropped chunks, the
    # Voxy off-switch and /voxysync. **It runs on the server too** - it adds packets and the sweep
    # is server-side - so it needs -AddMods on the release that publishes it. Its control law can
    # be exercised without a game: scripts\Test-FlowController.ps1.
    @{ Name = 'nbidal18-voxyworldgen'; Generator = $null; Builder = 'build_voxyworldgen.py' },
    # Sparse Structures records every structure set in one static TreeSet, filled from 26.2's
    # PARALLEL registry loader. A TreeSet cannot take concurrent writes: the tree corrupts and the
    # next insert throws, killing the server at boot with a NullPointerException naming whichever
    # mod was mid-insert - Incendium, in the one observed crash, which is innocent. Reproduced from
    # eight threads against the real class; fails on the first round. This serialises the writes.
    # The list only feeds a debug dump command, so there is no gameplay behaviour either way.
    # **Runs on the server too** - it is a server boot crash - so it needs -AddMods to deploy.
    @{ Name = 'nbidal18-sparsestructures'; Generator = $null; Builder = 'build_sparsestructures.py' },
    # A passenger who logs out of an aircraft comes back in mid-air: vanilla saves a ride only for
    # its sole passenger. Remembers the ridden entity by UUID (never the entity - two copies would
    # rebuild the plane twice, cargo included), puts the player back aboard or on the first solid
    # block or water below. Port of the 1.21.1 pack's nbidal18-safe-rejoin. Until 1.1.0 (v1.0.98) it
    # also counted a moving or airborne vehicle as activity; that went, see nbidal18-afk below. **Runs on the
    # server** - that is where it does anything - so it needs -AddMods to deploy.
    @{ Name = 'nbidal18-saferejoin'; Generator = $null; Builder = 'build_saferejoin.py' },
    # The idle kick back at five minutes (v1.0.98), counting only what a player actually does: keys,
    # mouse look, clicks, chat. Being moved - by the autopilot, a vehicle, water - no longer resets
    # the timer, which is how the owner starved flying on autopilot with nobody at the keyboard.
    # /afk holds the kick off until the player next does something. First-party content, no target.
    # **Runs on the server** - needs -AddMods.
    @{ Name = 'nbidal18-afk'; Generator = $null; Builder = 'build_afk.py' },
    # The End stays sealed until the owner opens it from the console (/theend open), so the server
    # goes in together as an event. Refuses the End portal's destination before vanilla builds the
    # platform, and any other teleport of a player into the End. Named for its target, vanilla's
    # End. **Runs on the dedicated server** - inert on a client and in singleplayer - so it needs
    # -AddMods to deploy.
    @{ Name = 'nbidal18-theend'; Generator = $null; Builder = 'build_theend.py' },
    # /strike <players>: a real lightning bolt on each named player - flash, thunder, the player and
    # the ground on fire - that hurts nobody and strikes nobody else. Vanilla's bolt has no damage
    # setting in 26.2 and its visual-only flag drops the fire too, so two wraps on bolts carrying the
    # command's tag. First-party content, no target. **Runs on the server** - needs -AddMods.
    @{ Name = 'nbidal18-strike'; Generator = $null; Builder = 'build_strike.py' },
    # A copper golem no longer opens a chest it has nothing to take from. Vanilla already works the
    # case out - its ContainerInteractionState separates PICKUP_NO_ITEM, and the condition behind it
    # is literally !container.isEmpty() - so the mixin only drops that state's reached-target action,
    # which is the whole open-lid performance. Depositing into an empty chest still opens it.
    # **Runs on the server** - needs -AddMods.
    @{ Name = 'nbidal18-coppergolem'; Generator = $null; Builder = 'build_coppergolem.py' },
    # Anvils without the prior-work penalty and without Too Expensive (v1.0.102 hotfix). The menu
    # mixin answers 0 for every REPAIR_COST read and writes 0 instead of the doubled penalty, and moves
    # the 40-level threshold out of reach - keeping vanilla's refusal to enchant a whole stack at once,
    # which prices at that same 40. The client mixin moves the label's own copy of the threshold.
    # **Both sides** - needs -AddMods.
    @{ Name = 'nbidal18-anvil'; Generator = $null; Builder = 'build_anvil.py' },
    # 26.2 bakes every inventory icon once into a cache texture (GuiItemAtlas) through the ordinary
    # item pipeline, which under Iris is the shader pipeline; Iris has no hook for that cache, so an
    # icon baked while a pipeline is being torn down or built comes out blank or as a grey blob and
    # stays that way until the cache is rebuilt - which a resource reload does not do. Flushes the
    # cache whenever Iris's pipeline or the block atlas changes, and for a few seconds after, so
    # every icon is re-baked once the pipeline has settled. Client only.
    @{ Name = 'nbidal18-iris'; Generator = $null; Builder = 'build_iris.py' },
    @{ Name = 'nbidal18-jei'; Generator = $null; Builder = 'build_jei.py' },
    # Voxy's internal errors go to the log instead of chat (v1.0.102). Its Logger.error writes the
    # log line and then posts the same text to chat through showInHUD; the mixin drops that post inside
    # error() only, so the log keeps everything and deliberate chat notices still arrive. Client only.
    @{ Name = 'nbidal18-voxy'; Generator = $null; Builder = 'build_voxy.py' },
    # Fresh Animations stands aside whenever the game has its own pose for the player's arms: any item
    # in use (bow, crossbow draw, spyglass, shield, trident, food, potions), a loaded crossbow held, or
    # a boat ride (v1.0.102). FA+Player replaces the arm rotations outright and never reads vanilla's
    # or Not Enough Animations' pose; the 1.21.1 pack fixed the bow the same way. No mixins - EMF's own
    # pause and vanilla-model conditions, as nbidal18-carryon and -reliablegliders use. Client only.
    @{ Name = 'nbidal18-emf'; Generator = $null; Builder = 'build_emf.py' },
    # LambDynamicLights' cell debug view labels light cells with their absolute coordinates, and any
    # player can switch it on in the mod's settings (v1.0.103, coordinates stripped from the game).
    # One mixin stops that renderer; the light-level and bounding-box views draw no position. Client.
    @{ Name = 'nbidal18-lambdynlights'; Generator = $null; Builder = 'build_lambdynlights.py' },
    # reduced_debug_info is set at every server start and put back if anyone turns it off (v1.0.103).
    # Every F3 source in the pack - vanilla, BetterF3, Sodium, Sodium Extra, each mod's entries - hides
    # absolute positions only under this rule, which had been set by hand. **Runs on the server** -
    # needs -AddMods.
    @{ Name = 'nbidal18-reduceddebug'; Generator = $null; Builder = 'build_reduceddebug.py' },
    # Vanilla Refresh's settings bridge, until v1.0.102 a hand-built jar with no builder. Its shipped jar
    # is now the fixed input in base\ and is copied byte for byte; the builder adds datapack overrides
    # that win because Fabric sorts mod data by dependency and this jar depends on Vanilla Refresh
    # exactly. v1.1.0 (v1.0.103): the compass readout shows Y and facing only. Data added, no javac.
    # **Runs on the server too** - needs -AddMods.
    @{ Name = 'nbidal18-vanillarefresh'; Generator = $null; Builder = 'build_vanillarefresh.py' },

    # Data only - no src\, so no javac. Its builder reads the vanilla loot table out of the game jar
    # and edits it, which is why it needs no classpath either.
    @{ Name = 'nbidal18-tectonic'; Generator = $null; Builder = 'build_tectonic.py' },
    # Every Xaero option the pack pins (minimap off, coordinates and cave mode hidden, teleport
    # denied) reads as its pin for the whole session, so the mods' own settings screens cannot
    # flip them until the updater repairs the file. One mixin at Xaero Lib's Config.get; the pin
    # list is generated from config-classification.json's propertyRules. Client only.
    @{ Name = 'nbidal18-xaerolib'; Generator = $null; Builder = 'build_xaerolib.py' },
    # Auto HUD's hotbar group (hotbar, hearts, food, level, mount health revealed together),
    # the mining trigger Auto HUD has no concept of, and the rule that the mount jump bar never
    # costs the experience bar its slot. Built through Auto HUD's published API - no mixin.
    # **Added to this list in v1.0.96**: it was hand-built until then and nothing here rebuilt
    # it, so its jar could have gone stale silently while its source moved on. Client only.
    @{ Name = 'nbidal18-autohud'; Generator = $null; Builder = 'build_autohud.py' },
    # HT's TreeChop, ported to 26.2 from the MIT continuation at polaron-games/treechop (1.21.11).
    # 191 upstream files that were never held to this build's -Xlint:all; they compile with the
    # warnings off (Lint below) rather than being rewritten. Errors still fail the build. Owner's
    # ask, 2026-09-04: TreeChop's chop-several-times mechanic, which no 26.x mod offers.
    @{ Name = 'nbidal18-treechop'; Generator = $null; Builder = 'build_treechop.py'; Lint = '-Xlint:none' }
)
if ($Only) {
    $mods = @($mods | Where-Object { $Only -contains $_.Name })
    if ($mods.Count -eq 0) { throw "No first-party mod matches: $($Only -join ', ')" }
}

# ---------------------------------------------------------------- classpath, from Prism's metadata
function Resolve-MavenPath([string] $prismRoot, [string] $coord) {
    $parts = $coord -split ':'
    $groupPath = ($parts[0] -replace '\.', '\')
    $fileName = if ($parts.Count -ge 4) { "$($parts[1])-$($parts[2])-$($parts[3]).jar" }
    else { "$($parts[1])-$($parts[2]).jar" }
    return Join-Path $prismRoot "libraries\$groupPath\$($parts[1])\$($parts[2])\$fileName"
}

$prismRoot = Join-Path $env:APPDATA 'PrismLauncher'
$instanceRoot = Join-Path $prismRoot "instances\$InstanceName"
$javaBin = Join-Path $prismRoot 'java\java-runtime-epsilon\bin'
$javac = Join-Path $javaBin 'javac.exe'
foreach ($required in @($instanceRoot, $javac)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing build input: $required" }
}

$releaseMods = Join-Path $ReleaseRoot '3. modpack\client\mods'
$classpath = [Collections.Generic.List[string]]::new()
$pack = Get-Content -LiteralPath (Join-Path $instanceRoot 'mmc-pack.json') -Raw | ConvertFrom-Json
foreach ($component in $pack.components) {
    $metaFile = Join-Path $prismRoot "meta\$($component.uid)\$($component.version).json"
    if (-not (Test-Path -LiteralPath $metaFile)) { continue }
    $meta = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json
    $names = $meta.PSObject.Properties.Name
    $coords = @()
    if (($names -contains 'mainJar') -and $meta.mainJar) { $coords += $meta.mainJar.name }
    if (($names -contains 'libraries') -and $meta.libraries) { $coords += $meta.libraries.name }
    foreach ($coord in $coords) {
        if ($coord -match 'natives-(linux|macos)') { continue }
        $path = Resolve-MavenPath $prismRoot $coord
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $classpath.Contains($path)) {
            $classpath.Add($path)
        }
    }
}
foreach ($jar in Get-ChildItem -LiteralPath $releaseMods -Filter *.jar) {
    if ($jar.Name -like 'nbidal18-*') { continue }
    $classpath.Add($jar.FullName)
}
# A fork compiles against the upstream jar it patches, which by then has been replaced in mods\ by
# the fork itself - so the original is kept in the mod's own dl\ and added here. Without this a
# fork can only be built once, and never rebuilt.
$customModsRoot = Join-Path $ReleaseRoot '5. modpack source\custom mods'
if (Test-Path -LiteralPath $customModsRoot) {
    foreach ($jar in Get-ChildItem -LiteralPath $customModsRoot -Recurse -Filter *.jar -File |
        Where-Object { $_.Directory.Name -eq 'dl' }) {
        if (-not $classpath.Contains($jar.FullName)) { $classpath.Add($jar.FullName) }
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$jijRoot = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-jij'
if (Test-Path -LiteralPath $jijRoot) { Remove-Item -LiteralPath $jijRoot -Recurse -Force }
New-Item -ItemType Directory -Path $jijRoot | Out-Null
$nested = 0
# Fabric Loader nests MixinExtras (com.llamalad7.mixinextras) the same way the mods nest their
# libraries, and a mixin using @Local needs it at compile time. v1.0.74 was the first to.
$nestingHosts = @(Get-ChildItem -LiteralPath $releaseMods -Filter *.jar)
$nestingHosts += @($classpath | Where-Object { (Split-Path $_ -Leaf) -like 'fabric-loader-*.jar' } | ForEach-Object { Get-Item -LiteralPath $_ })
try {
    foreach ($jar in $nestingHosts) {
        $archive = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -notlike 'META-INF/jars/*.jar') { continue }
                $target = Join-Path $jijRoot ($jar.BaseName + '__' + (Split-Path $entry.FullName -Leaf))
                if (-not (Test-Path -LiteralPath $target)) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                }
                if (-not $classpath.Contains($target)) { $classpath.Add($target); $nested++ }
            }
        }
        finally { $archive.Dispose() }
    }

    if ($classpath.Count -eq 0) { throw 'The classpath resolved to nothing.' }
    Write-Host ("release   {0}" -f $ReleaseRoot)
    Write-Host ("classpath {0} jars ({1} nested inside other mods)" -f $classpath.Count, $nested)

    $customMods = Join-Path $ReleaseRoot '5. modpack source\custom mods'

    foreach ($mod in $mods) {
        $name = $mod.Name
        $modRoot = Join-Path $customMods $name
        if (-not (Test-Path -LiteralPath $modRoot)) { throw "No source for $name at $modRoot" }

        if ($mod.Generator) {
            Push-Location $modRoot
            try {
                & python $mod.Generator | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "$($mod.Generator) failed for $name" }
            }
            finally { Pop-Location }
        }

        # A first-party artefact may be data only - a loot table or a datapack override with no Java
        # at all. Those skip the compile entirely rather than being made to carry an empty src\.
        # Assigned in two statements, not as an if-expression: under StrictMode the empty branch
        # yields $null rather than an empty array, and $sources.Count then throws.
        $srcRoot = Join-Path $modRoot 'src'
        $sources = @()
        if (Test-Path -LiteralPath $srcRoot) {
            $sources = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -Filter *.java)
        }
        if ((Test-Path -LiteralPath $srcRoot) -and $sources.Count -eq 0) {
            throw "$modRoot has a src\ directory but no .java in it"
        }
        if ($sources.Count -eq 0) {
            Push-Location $modRoot
            try {
                & python $mod.Builder
                if ($LASTEXITCODE -ne 0) { throw "$($mod.Builder) failed for $name" }
            }
            finally { Pop-Location }
            continue
        }
        $out = Join-Path ([IO.Path]::GetTempPath()) "nbidal18-build-$name"
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        New-Item -ItemType Directory -Path $out | Out-Null

        # An @argfile carrying BOTH the classpath and the sources. Fabric API alone contributes ~190
        # nested jars, and passing that on the command line fails with "the filename or extension is
        # too long" before javac ever starts.
        #
        # Forward slashes throughout: javac's argfile parser treats a backslash inside a quoted
        # string as an escape, so a Windows path written literally is silently mangled. Quoted
        # because the release path contains spaces.
        $argFile = Join-Path $out 'javac-args.txt'
        $fwd = [char]47
        $bsl = [char]92
        $argLines = @('-cp', ('"' + ($classpath -join ';').Replace($bsl, $fwd) + '"'))
        $argLines += $sources | ForEach-Object { '"' + $_.FullName.Replace($bsl, $fwd) + '"' }
        [IO.File]::WriteAllText($argFile, ($argLines -join "`n"), (New-Object Text.UTF8Encoding($false)))

        # -Werror on purpose. The 1.21.1 build once packaged a 776-byte jar from a failed compile
        # because nothing checked the exit code; this refuses to reach the packaging step at all.
        #
        # -classfile  Minecraft's own @Contract annotations warn on every build
        # -serial     a checked exception without a serialVersionUID is not a defect here
        # -path       a mod's manifest Class-Path names sibling jars this pack does not ship, so
        #             javac reports "bad path element" for jars nothing needs. That is a fact about
        #             somebody else's manifest, not about our code, and -Werror would fail on it.
        #
        # One quoted token: PowerShell splits an unquoted -Xlint:all,-classfile,-serial on the
        # commas and javac then sees "-classfile" as a flag of its own, which it rejects.
        # A ported third-party codebase may set Lint on its entry to compile without the pack's
        # own warning set; -Werror stays, so any warning the chosen set still raises is fatal.
        $lint = '-Xlint:all,-classfile,-serial,-path'
        if ($mod.ContainsKey('Lint') -and $mod.Lint) { $lint = $mod.Lint }
        # -Xmaxerrs: javac stops listing at 100 by default, which for a ported codebase hides the
        # shape of the work behind the first hundred cascades. Everything is listed.
        # javac writes its notes ("Some input files use or override a deprecated API") to stderr even
        # on a clean compile, and under $ErrorActionPreference = 'Stop' PowerShell 5.1 turns a native
        # command's stderr into a terminating error the moment the caller redirects output. That
        # killed New-Release at the TreeChop build (v1.0.73) while the same command in a console
        # passed. The exit code is the verdict; stderr is just shown.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $javac -encoding UTF-8 $lint -Werror -Xmaxerrs 5000 -d $out "@$argFile" 2>&1 | ForEach-Object { Write-Host ("javac     " + $_) }
            $javacExit = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($javacExit -ne 0) { throw "javac failed for $name" }

        Push-Location $modRoot
        try {
            & python $mod.Builder $out
            if ($LASTEXITCODE -ne 0) { throw "$($mod.Builder) failed for $name" }
        }
        finally { Pop-Location }
        Remove-Item -LiteralPath $out -Recurse -Force
    }
}
finally {
    if (Test-Path -LiteralPath $jijRoot) { Remove-Item -LiteralPath $jijRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- retire superseded jars
# Every first-party jar carries a version in its file name, so building a new one leaves the old one
# beside it. Two jars in mods\ is not a warning at runtime, it is a second mod claiming the same id,
# and the loader picks one.
#
# This covered only the integrity helper until v1.0.48, because the helper is the one whose version
# moves every release. That was the wrong reason to single it out: any first-party mod leaves the
# same wreckage the moment its own version is bumped, and voxyworldgen did it twice in one day -
# 1.2.0 beside 1.3.0, then 1.3.0 beside 1.4.0. Both were caught by eye. The second one would have
# shipped a client that could not start.
foreach ($stale in Get-ChildItem -LiteralPath $releaseMods -Filter 'nbidal18-integrity-*.jar') {
    if ($stale.Name -notlike "*-$version+*") {
        [IO.File]::Delete($stale.FullName)
        Write-Host ("retired   {0}" -f $stale.Name)
    }
}
$helpers = @(Get-ChildItem -LiteralPath $releaseMods -Filter 'nbidal18-integrity-*.jar')
if ($helpers.Count -ne 1) { throw "Expected one integrity helper, found $($helpers.Count)" }

# The rest carry their own versions, which move on their own schedule, so the survivor is the one
# this run just wrote rather than the one matching the pack version. Scoped to the exact mod name
# each time - nothing outside `<mod>-*.jar` is ever a candidate.
foreach ($mod in $mods) {
    $siblings = @(Get-ChildItem -LiteralPath $releaseMods -Filter ("{0}-*.jar" -f $mod.Name) -File |
            Sort-Object LastWriteTimeUtc -Descending)
    if ($siblings.Count -lt 2) { continue }
    foreach ($stale in $siblings[1..($siblings.Count - 1)]) {
        [IO.File]::Delete($stale.FullName)
        Write-Host ("retired   {0}  (superseded by {1})" -f $stale.Name, $siblings[0].Name)
    }
}

Write-Host ''
Write-Host ("OK        {0} first-party mod(s) built into v{1}." -f $mods.Count, $version)
