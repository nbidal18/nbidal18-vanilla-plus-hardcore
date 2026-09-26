<#
    Starts a real client against a throwaway game directory, waits for the title screen, and then
    reads the log for the faults that have actually shipped from this pack.

      scripts\Test-ClientLaunch.ps1
      scripts\Test-ClientLaunch.ps1 -KeepGameDir     leave the directory for inspection
      scripts\Test-ClientLaunch.ps1 -Hold -ReplaceShader <zip> -World <saves> -QuickPlay <level>
                                                     start inside a world with that shader on

    Ported from the 1.21.1 pack, which wrote it after v4.2.3 and v4.2.4 both shipped a client that
    could not start. This line has not had that failure - but it has had three of a different kind,
    and all three were in the log the whole time while nobody read it:

      v1.0.6  a resource pack's core item shader blanked every inventory slot, and the game said
              "shader program does not use sampler Sampler1" on every load
      v1.0.7  a pack's models rendered untextured, and the game said "Missing texture references"
      v1.0.10 nbidal18-invmov did nothing at all, and the tell was a line that never appeared

    So this checks two things: that the client reaches the title screen, and that the log does not
    contain a pattern that has previously cost a release.

    Nothing here touches the real Prism instance. The classpath is rebuilt from Prism's own metadata,
    so the launcher does not need to be running and the libraries are exactly the ones players get.

    The integrity helper is removed from the throwaway copy: it enforces the published channel and
    the Prism instance layout, neither of which exists here, and it refuses before the main menu when
    they are missing. Verify-PublishedChannel covers what it would have checked.

    Mixins apply on class load, so reaching the title screen proves every mixin targeting a class
    loaded during startup. A mixin into a screen that opens later still needs a play-test.
#>
[CmdletBinding()]
param(
    [int] $BootTimeoutSeconds = 300,
    [string] $InstanceName = 'nbidal18-vanilla-plus-client',
    # Stage from this folder instead of the release's "3. modpack\client". Added 2026-09-21 for the
    # v2.0.0 rebuild, which builds a pack up one mod at a time inside a Prism instance that is not a
    # release and has no client source of its own. Everything else about the run is unchanged, so a
    # mod is proved by the same check the pack already trusts rather than by a second one.
    #
    #   .\Test-ClientLaunch.ps1 -InstanceName nbidal18-rebuild `
    #       -ClientSource "$env:APPDATA\PrismLauncher\instances\nbidal18-rebuild\minecraft"
    [string] $ClientSource,
    [switch] $KeepGameDir,
    # Leave the client running at the title screen instead of killing it, and keep the game
    # directory. For looking at something that only exists on screen - a GUI, a model, a shader -
    # which no log line can confirm.
    #
    # It exists because the alternative was cutting a release per attempt. The updater keeps
    # resourcepacks exact-match, so a candidate pack dropped into the real instance is deleted
    # before the game starts; this directory has no updater and no integrity helper.
    [switch] $Hold,
    # Let the client take the foreground as it normally would. Off by default since 2026-09-21: a
    # test run that steals focus has alt-tabbed the owner out of hardcore Minecraft and out of
    # Rocket League, and no run needs the screen to decide pass or fail - that is read from the log.
    # Pass this when you deliberately want the client in front of you.
    [switch] $Focus,
    # How long to keep pushing the client's window back after the title screen is reached. Minecraft
    # raises its window once resource packs finish loading, which is after the log line this test
    # waits on, so suppression has to outlive the check itself.
    [int] $FocusGraceSeconds = 25,
    # Copy these files over the staged resourcepacks folder, by name, after staging. A candidate
    # fork of a pack the release already ships replaces the shipped one.
    [string[]] $ReplacePack = @(),
    # Copy these files over the staged config folder, by name. Same idea as -ReplacePack, for the
    # settings a rendering question turns on.
    [string[]] $ReplaceConfig = @(),
    # Stage this shader zip and switch Iris on with it selected, so the run starts with the shader
    # already applied. Added 2026-09-17 for the IntegratedPBR port: shaderpacks is exact-match, so a
    # candidate shader in the real instance is moved out by the updater and, worse, refuses the
    # server login until it is - which is not a thing to ask the owner to work around by hand.
    #
    # A shader only compiles once a world is loaded, so pair this with -World and -QuickPlay, or
    # -Hold and open a world yourself. Without a world on screen the run proves nothing about it.
    [string] $ReplaceShader,
    # A saves folder to restore into the throwaway instance, so a run can start inside a world.
    # Container GUIs, held items and anything else that only exists in game cannot be reached from
    # the title screen, and creating a world by hand every run made that a person's job.
    [string] $World,
    # Load straight into this level and skip the menus. Needs -World.
    [string] $QuickPlay,
    # Connect straight to this server (host:port) and skip the menus - the multiplayer twin of
    # -QuickPlay, for behaviour that only shows after a server session. Added 2026-09-24 to
    # reproduce the exit hang the owner hit after playing on the hardcore server: the throwaway
    # has no integrity helper, so the server it joins must be one that does not require it (a
    # local Test-DedicatedServer run with the policy removed). Uses the same "joined the game"
    # log line as -QuickPlay to decide the session began.
    [string] $QuickPlayServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The client keeps latest.log open while it runs, so a plain read fails with a sharing violation.
function Read-SharedText([string] $path) {
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

# group:artifact:version[:classifier] -> the path Prism stores it at.
function Resolve-MavenPath([string] $prismRoot, [string] $coord) {
    $parts = $coord -split ':'
    $groupPath = ($parts[0] -replace '\.', '\')
    $fileName = if ($parts.Count -ge 4) { "$($parts[1])-$($parts[2])-$($parts[3]).jar" }
    else { "$($parts[1])-$($parts[2]).jar" }
    return Join-Path $prismRoot "libraries\$groupPath\$($parts[1])\$($parts[2])\$fileName"
}

$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
$clientSource = if ($ClientSource) { $ClientSource } else { Join-Path $release '3. modpack\client' }
$mcVersion = (Get-Content -LiteralPath (Join-Path $repo 'MINECRAFT.txt') -Raw).Trim()
$prismRoot = Join-Path $env:APPDATA 'PrismLauncher'
$instanceRoot = Join-Path $prismRoot "instances\$InstanceName"
$javaPath = Join-Path $prismRoot 'java\java-runtime-epsilon\bin\java.exe'

foreach ($required in @($clientSource, $prismRoot, $instanceRoot, $javaPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing input: $required" }
}

# ---------------------------------------------------------------- classpath, from Prism's metadata
$classpath = [Collections.Generic.List[string]]::new()
$mainClass = $null
$assetIndex = $null
$pack = Get-Content -LiteralPath (Join-Path $instanceRoot 'mmc-pack.json') -Raw | ConvertFrom-Json
foreach ($component in $pack.components) {
    $metaFile = Join-Path $prismRoot "meta\$($component.uid)\$($component.version).json"
    if (-not (Test-Path -LiteralPath $metaFile)) { continue }
    $meta = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json
    $names = $meta.PSObject.Properties.Name
    if (($names -contains 'mainClass') -and $meta.mainClass) { $mainClass = $meta.mainClass }
    if (($names -contains 'assetIndex') -and $meta.assetIndex) { $assetIndex = $meta.assetIndex.id }
    $coords = @()
    if (($names -contains 'mainJar') -and $meta.mainJar) { $coords += $meta.mainJar.name }
    if (($names -contains 'libraries') -and $meta.libraries) { $coords += $meta.libraries.name }
    foreach ($coord in $coords) {
        # LWJGL declares natives for every platform; Prism downloads only this one, so whether the
        # file exists is a better filter than reimplementing Prism's rule engine.
        if ($coord -match 'natives-(linux|macos)') { continue }
        $path = Resolve-MavenPath $prismRoot $coord
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $classpath.Contains($path)) {
            $classpath.Add($path)
        }
    }
}
if (-not $mainClass) { throw 'No mainClass in the Prism component metadata.' }
if (-not $assetIndex) { throw 'No assetIndex in the Prism component metadata.' }
if ($classpath.Count -eq 0) { throw 'The classpath resolved to nothing.' }

# ---------------------------------------------------------------- patterns that have cost a release
#
# Curated, not "every warning". This pack logs plenty of benign noise - Overlay's uses a `layer`
# value 26.2 dropped, Continuity references sprites a pack does not ship - and failing on all of it
# would make the check cry wolf until nobody ran it, which is how Verify-PublishedChannel nearly
# went wrong. Each entry below is a fault that actually reached players.
$fatalPatterns = @(
    @{ Name = 'core shader incompatible with the pipeline'
        Pattern = 'shader program does not use sampler'
        Note = 'a resource pack is overriding shaders/core for a different game version (v1.0.6)' }
    @{ Name = 'model with unresolved textures'
        Pattern = 'Missing texture references in model'
        Note = 'a resource pack ships models whose texture variables are undefined (v1.0.7)'
        # Traveler's Backpack ships its backpack geometry as loose Blockbench sources under
        # models/block/. Measured against the jar rather than assumed: of 89 models there, 76 are
        # referenced by a blockstate, item model or parent chain and 13 are not - and every one of
        # the 13 is a backpack_* file, while not one referenced model starts with backpack_. The
        # mod's renderer loads that geometry itself, so nothing goes through the model registry and
        # nothing renders untextured; the loader simply parses every file in the folder and warns.
        #
        # The v1.0.7 fault this pattern exists for was the opposite case - models that were in use
        # and untextured - so the check stays live for every other model, including the other 76.
        Except = 'travelersbackpack:block/backpack_' }
    @{ Name = 'malformed JSON in a resource pack'
        Pattern = 'MalformedJsonException'
        Note = 'a pack ships JSON the game cannot parse and silently drops (v1.0.7)' }
    @{ Name = 'invalid namespace in a resource pack'
        Pattern = 'Non \[a-z0-9_\.-\] character in namespace'
        Note = 'a pack ships a folder name Minecraft rejects outright (v1.0.7)'
        # macOS litter, not a broken pack. Os' Colorful Grasses (Mix).zip was zipped on a Mac and
        # carries assets/.DS_Store plus a __MACOSX/ tree - 14 entries, none of them game content -
        # so the game reads ".DS_Store" as a namespace and ignores it. Nothing is lost: the pack's
        # textures are all under assets/minecraft/. Excepted rather than repacked because the same
        # zip ships in the live Vanilla+ release, and editing it here would diverge the two packs
        # over a log line. A genuine bad namespace is any other name and still fails.
        Except = 'namespace \.DS_Store' }
)

# Only with -ReplaceShader, because nothing else in this pack turns Iris on. A shader that fails to
# compile falls back to vanilla rendering and keeps playing, so the screen alone does not tell you -
# the world just looks unshaded, which is exactly what a person is least likely to notice when they
# are looking for a subtle change in how textures catch light.
if ($ReplaceShader) {
    $fatalPatterns += @{ Name = 'shader failed to compile'
        Pattern = 'ShaderCompileException|[Ff]ailed to compile|shader compilation failed|[Ff]ailed to initialize shader'
        Note = 'Iris could not build the selected pack and fell back to vanilla rendering' }
}

# Lines that must be present. An absent line is the hardest failure to notice: nbidal18-invmov
# shipped doing nothing while everything that could report success did.
#
# Only lines that a client reaching the TITLE SCREEN can actually produce belong here. "JEI runtime
# captured" does not: JEI publishes its runtime once a world loads, so requiring it failed a
# perfectly healthy client on this check's first run. What guards that path instead is the mod's own
# startup error if its jei_mod_plugin entrypoint is missing, plus build_invmov.py refusing to
# package a jar whose declared entrypoints are not all present.
$requiredLines = @(
    # Matches both module names, so losing either one fails here rather than shipping a bridge that
    # loads and does half its job. v1.0.10's did exactly that with the JEI half.
    @{ Name = 'InvMove bridge registered'
        Pattern = 'Registered the JEI search and allow-movement modules with InvMove'
        RequiresMod = 'nbidal18-invmov-*.jar' }
    # The exception to the title-screen rule above, and a safe one: this companion is only staged
    # when -World is given (see the world block), and a hosted world is exactly when it prints. It
    # proves the throwaway's world runs the server's Vanilla Refresh settings, not stock ones.
    @{ Name = 'Vanilla Refresh settings applied from the server master'
        Pattern = 'Applied \d+ Vanilla Refresh settings from config'
        RequiresMod = 'nbidal18-vanillarefresh-*.jar' }
)

$mixinFailure = '(?m)(org\.spongepowered\.asm\.mixin\..*throwables\.|Mixin apply failed|' +
'MixinApplyError|MixinTransformerError|Critical injection failure|Mixin transformation of .* failed)'

# Keeping the test client out of the foreground. A pass/fail run is read from the log, never from
# the screen, so the window has no business being in front of whatever the owner is doing - and a
# hardcore death caused by a build step is a real cost, not a papercut.
#
# ShowWindow(SW_SHOWMINNOACTIVE) rather than SW_MINIMIZE: the latter activates the next window in
# the z-order, which on a single-monitor desktop is often the one we just came from and sometimes
# is not. Restoring the recorded window explicitly is what makes it land back where it started.
# The game keeps running while minimized - Minecraft throttles its frame rate but the start-up
# sequence, which is all this test reads, runs on other threads regardless.
if (-not ('Nbidal18Focus' -as [type])) {
    Add-Type -Namespace '' -Name 'Nbidal18Focus' -MemberDefinition @'
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr p);

    // Windows refuses SetForegroundWindow from a process that does not already own the foreground,
    // which is exactly our situation - so the plain call can silently do nothing. Attaching our
    // input queue to the thread that owns the foreground window lifts that restriction for the
    // duration of the call. Without this the client's window was minimized but focus did not always
    // come back to where it started.
    static void ForceForeground(IntPtr hWnd) {
        IntPtr current = GetForegroundWindow();
        if (current == hWnd) { return; }
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(current, out dummy);
        uint ours = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != ours && AttachThreadInput(ours, fgThread, true);
        try { SetForegroundWindow(hWnd); }
        finally { if (attached) { AttachThreadInput(ours, fgThread, false); } }
    }

    // Minimize every visible top-level window owned by `processId`, then put `restore` back in
    // front. Returns quietly if the game has not created its window yet.
    public static void KeepBehind(int processId, IntPtr restore) {
        bool touched = false;
        EnumWindows(delegate(IntPtr hWnd, IntPtr p) {
            uint owner; GetWindowThreadProcessId(hWnd, out owner);
            if (owner == (uint)processId && IsWindowVisible(hWnd)) {
                ShowWindow(hWnd, 7 /* SW_SHOWMINNOACTIVE */);
                touched = true;
            }
            return true;
        }, IntPtr.Zero);
        if (touched && restore != IntPtr.Zero) { ForceForeground(restore); }
    }
'@
}

# Short path on purpose: the deepest datapack file passes MAX_PATH from a longer root.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-vp-launch'

try {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    foreach ($directory in @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')) {
        $source = Join-Path $clientSource $directory
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $testRoot $directory) -Recurse -Force
        }
    }
    foreach ($drop in Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File -Filter 'nbidal18-integrity-*.jar') {
        Remove-Item -LiteralPath $drop.FullName -Force
    }
    $stagedMods = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File -Filter '*.jar').Count
    Write-Host ("staging   {0} mods into {1}" -f $stagedMods, $testRoot)

    foreach ($candidate in $ReplacePack) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "-ReplacePack: no file at $candidate" }
        $dest = Join-Path (Join-Path $testRoot 'resourcepacks') (Split-Path $candidate -Leaf)
        $verb = if (Test-Path -LiteralPath $dest) { 'replaced' } else { 'added   ' }
        Copy-Item -LiteralPath $candidate -Destination $dest -Force
        Write-Host ("{0}  {1}" -f $verb, (Split-Path $candidate -Leaf))
    }

    # The staged instance has no options.txt, so the game would boot with every pack switched off
    # and prove nothing about how they look. Both rows are copied from the release, which is what
    # the updater seeds onto a player's instance.
    foreach ($candidate in $ReplaceConfig) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "-ReplaceConfig: no file at $candidate" }
        Copy-Item -LiteralPath $candidate -Destination (Join-Path (Join-Path $testRoot 'config') (Split-Path $candidate -Leaf)) -Force
        Write-Host ("config    {0}" -f (Split-Path $candidate -Leaf))
    }

    # Iris keeps the selected pack and the on/off switch in config\iris.properties, so staging the
    # zip is only half of it: without these two keys the client boots with shaders off and the run
    # shows the pack's normal look. The file is rewritten key by key, keeping everything else Iris
    # stores there (colour space, shadow distance).
    if ($ReplaceShader) {
        if (-not (Test-Path -LiteralPath $ReplaceShader -PathType Leaf)) { throw "-ReplaceShader: no file at $ReplaceShader" }
        $shaderName = Split-Path $ReplaceShader -Leaf
        $shaderDir = Join-Path $testRoot 'shaderpacks'
        if (-not (Test-Path -LiteralPath $shaderDir)) { New-Item -ItemType Directory -Path $shaderDir | Out-Null }
        $dest = Join-Path $shaderDir $shaderName
        $verb = if (Test-Path -LiteralPath $dest) { 'replaced' } else { 'added   ' }
        Copy-Item -LiteralPath $ReplaceShader -Destination $dest -Force
        Write-Host ("{0}  {1}" -f $verb, $shaderName)

        $irisPath = Join-Path (Join-Path $testRoot 'config') 'iris.properties'
        $irisRows = if (Test-Path -LiteralPath $irisPath) {
            @([IO.File]::ReadAllText($irisPath) -split "`r?`n" | Where-Object { $_ -ne '' })
        }
        else { @() }
        $irisRows = @($irisRows | Where-Object { $_ -notmatch '^(enableShaders|shaderPack)=' })
        $irisRows += @('enableShaders=true', "shaderPack=$shaderName")
        [IO.File]::WriteAllText($irisPath, (($irisRows -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        Write-Host ("shader    iris.properties selects {0} with shaders on" -f $shaderName)
        if (-not $World) {
            Write-Warning ('A shader compiles when a world loads. With no -World this run reaches ' +
                'the title screen with the shader selected and never compiles it.')
        }
    }

    if ($World) {
        if (-not (Test-Path -LiteralPath $World -PathType Container)) { throw "-World: no folder at $World" }
        Copy-Item -LiteralPath $World -Destination (Join-Path $testRoot 'saves') -Recurse -Force
        Write-Host ("world     restored {0}" -f ((Get-ChildItem -LiteralPath $World -Directory | ForEach-Object { $_.Name }) -join ', '))

        # A world in the throwaway is hosted by the client's own integrated server, and the client we
        # ship has no Vanilla Refresh companion - it is staged on the server only, deliberately, so
        # nobody gets a Mod Menu screen the dedicated server never reads. Without it a test world runs
        # Vanilla Refresh on stock values: sitting on, souls on, everything the server has switched
        # off. Owner, 2026-09-26, looking at exactly that: "make sure the test instance fetches the
        # latest configs, its a duplicate of what we ship". So the server's companion and the server
        # master it reads are staged beside the client's mods whenever there is a world to host. The
        # log then says "Applied 98 Vanilla Refresh settings from config", which the check below
        # requires. Nothing here changes what is shipped.
        #
        # The same holds for every server-only mod that shapes a world rather than a player: each
        # row is a jar pattern in 4. server\mods and the server master it reads. Preferred Gamerules
        # joined 2026-09-26 (owner: "include the preferred gamerules mod with these two rules") - it
        # sets the DEFAULT of a rule, so it shapes worlds created in the throwaway, not the restored one.
        $serverMods = Join-Path $release '4. server\mods'
        $worldShapers = @(
            @{ Jar = 'nbidal18-vanillarefresh-*.jar'; Config = 'nbidal18-vanillarefresh.json'; Gives = 'Vanilla Refresh settings' },
            @{ Jar = 'preferred-gamerules-*.jar'; Config = 'preferred-gamerules.properties'; Gives = 'game-rule defaults' }
        )
        foreach ($shaper in $worldShapers) {
            $jar = @(Get-ChildItem -LiteralPath $serverMods -File -Filter $shaper.Jar -ErrorAction SilentlyContinue)
            $serverConfig = Join-Path (Join-Path $release '4. server\config') $shaper.Config
            if ($jar.Count -ne 1 -or -not (Test-Path -LiteralPath $serverConfig -PathType Leaf)) {
                throw ("-World needs {0} and {1} in 4. server\, so the hosted world runs the server's {2} and not stock ones." -f
                    $shaper.Jar, $shaper.Config, $shaper.Gives)
            }
            Copy-Item -LiteralPath $jar[0].FullName -Destination (Join-Path $testRoot 'mods') -Force
            Copy-Item -LiteralPath $serverConfig -Destination (Join-Path $testRoot 'config') -Force
            Write-Host ("server    {0} and {1} staged, so the hosted world runs the server's {2}" -f $jar[0].Name, $shaper.Config, $shaper.Gives)
        }
    }

    # Seeded on every run, not just -Hold. Without these two rows the staged client boots with every
    # resource pack switched off, and the two failures this script was written for - v1.0.6's blanked
    # inventory slots from a pack's core item shader, v1.0.7's "Missing texture references" - are both
    # failures that can only happen once a pack is actually selected. Staging the zips and leaving
    # them unselected proved the folder copied, nothing more. Changed 2026-09-23, when the hardcore
    # rebuild enabled nine packs, three of which the game marks format-incompatible and runs anyway.
    $releaseOptions = Join-Path $clientSource 'options.txt'
    if (Test-Path -LiteralPath $releaseOptions -PathType Leaf) {
        # The version row comes too, and it is not optional: without it the game reads options.txt as a
        # pre-1.13 file and runs its old key-code converter over every key_ row, parsing the value as
        # an integer. The updater's seeds add key_ rows (pick block unbound, hotbar 1 on the bracket),
        # so the file then fails to load - "NumberFormatException: key.keyboard.unknown" - and the
        # game boots on defaults with every pack switched off. Found 2026-09-26, first seeded run.
        #
        # onboardAccessibility comes too. The master has it false, as every instance that has ever
        # been played does; without the row the game shows its first-launch accessibility screen
        # and runs quick play only after that screen is dismissed - so a -QuickPlay run sits on the
        # title panorama for the whole timeout with a healthy render thread and no server thread.
        # Found 2026-09-26, second seeded run, by thread dump.
        $rows = @(([IO.File]::ReadAllText($releaseOptions) -split "`r?`n") |
            Where-Object { $_ -match '^(version|onboardAccessibility|resourcePacks|incompatibleResourcePacks):' })
        # Music off in every throwaway. Owner, 2026-09-26, mid-check: "about the test world, have
        # music set to off too". Only the pack rows come from the release; everything else is the
        # game's default, and the default plays music over a visual check.
        $rows += 'soundCategory_music:0.0'
        [IO.File]::WriteAllText((Join-Path $testRoot 'options.txt'), (($rows -join "`n") + "`n"),
            (New-Object Text.UTF8Encoding($false)))
        Write-Host ("seeded    options.txt with {0} rows from the client source (version, onboarding, packs), music off" -f ($rows.Count - 1))
    }
    else {
        Write-Warning ('No options.txt in the client source, so every resource pack boots ' +
            'switched off and this run proves nothing about them.')
    }

    # The updater's own seeds, applied by the updater's own code. Staging copies the shipped files as
    # they are in the source, but a player never sees them that way: on Play the updater applies
    # this release's one-time defaults on top - Sodium Extra's coordinates off, the owner's
    # options.txt rows, Complementary selected, the two servers. A throwaway without that step
    # showed every one of those at its shipped value (owner, 2026-09-26: "the sodium extra show
    # coordinates is still there"). The jar is the one Build-Updater just built, so the seeds tested
    # here are the seeds that ship; --seed-only runs them against the throwaway and nothing else.
    $updaterJar = Join-Path (Split-Path -Parent $PSScriptRoot) 'client\nbidal18-packwiz-updater.jar'
    if (-not (Test-Path -LiteralPath $updaterJar -PathType Leaf)) {
        throw "No updater jar at $updaterJar - run scripts\Build-Updater.ps1 first; the throwaway's seeds come from it."
    }
    $env:INST_MC_DIR = $testRoot
    $env:NBIDAL18_HEADLESS_TEST = '1'
    # The updater prints its warnings on stderr, and under $ErrorActionPreference = 'Stop' Windows
    # PowerShell raises a native command's stderr as a terminating error before the exit code can be
    # read (the same trap Build-PackwizSite documents around git). Relaxed for the call only.
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $seedOutput = @(& $javaPath -jar $updaterJar --seed-only 2>&1 | ForEach-Object { $_.ToString() })
        $seedExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
        Remove-Item Env:INST_MC_DIR, Env:NBIDAL18_HEADLESS_TEST -ErrorAction SilentlyContinue
    }
    foreach ($line in $seedOutput | Where-Object { $_ -match 'WARNING' }) { Write-Warning ($line -replace '^\[nbidal18 packwiz\] WARNING: ', '') }
    if ($seedExit -ne 0) { throw ("The updater's --seed-only pass failed:`n" + ($seedOutput -join "`n")) }
    $applied = @($seedOutput | Where-Object { $_ -match "Applied this release's defaults to (\S+)" } |
        ForEach-Object { $Matches[1].TrimEnd(';') })
    Write-Host ("seeded    {0} release default(s) applied by the updater itself, to: {1}" -f $applied.Count,
        (($applied | Select-Object -Unique) -join ', '))

    $arguments = @(
        '-Xms512m', '-Xmx2048m',
        '-cp', ($classpath -join ';'),
        $mainClass,
        '--username', 'LaunchCheck',
        '--version', $mcVersion,
        '--gameDir', $testRoot,
        '--assetsDir', (Join-Path $prismRoot 'assets'),
        '--assetIndex', $assetIndex,
        '--uuid', '00000000000000000000000000000000',
        '--accessToken', '0',
        '--userType', 'legacy',
        '--versionType', 'release'
    )
    if ($QuickPlay) { $arguments += @('--quickPlaySingleplayer', $QuickPlay) }
    if ($QuickPlayServer) { $arguments += @('--quickPlayMultiplayer', $QuickPlayServer) }

    # WorkingDirectory matters as much as --gameDir: several mods write relative to the process
    # working directory, and launching from the checkout once scattered files through the repo.
    # The Java console only; the game's own window is GLFW's and is handled below.
    $client = Start-Process -FilePath $javaPath -ArgumentList $arguments -PassThru `
        -WorkingDirectory $testRoot -WindowStyle $(if ($Hold -and $Focus) { 'Normal' } else { 'Minimized' }) `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')

    # -WindowStyle above only governs the Java console. The game's own window is created by GLFW a
    # few seconds later and takes the foreground on its own, which is why a "minimized" test run
    # still alt-tabbed the owner out of whatever he was playing (reported 2026-09-21: "wouldn't want
    # to die cuz I got alt tabbed", and it hits Rocket League too). Nothing passed to Start-Process
    # can prevent that, so the window is pushed back as it appears - every second for the whole boot,
    # because GLFW shows it late and Minecraft raises it again when the render thread starts.
    # Suppressed during start-up for EVERY run, -Hold included. The first version exempted -Hold on
    # the reasoning that looking at the client is its whole purpose - which got it backwards: -Hold
    # is precisely the run that stays on screen for minutes, so it is the one most likely to be
    # going while the owner is in a game. Suppression stops the moment the title screen is reached,
    # so a -Hold client can be raised from the taskbar and will then stay raised; nothing fights the
    # window once it is yours. -Focus opts back in for a run you want to land in front of you.
    $userWindow = if ($Focus) { [IntPtr]::Zero } else { [Nbidal18Focus]::GetForegroundWindow() }
    $client.Refresh()

    $logPath = Join-Path $testRoot 'logs\latest.log'
    try {
        $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
        $reachedMenu = $false
        while ((Get-Date) -lt $deadline -and -not $client.HasExited) {
            # The window is chased at 100 ms and the log is read once a second. At the original one
            # second the client sat in front for up to a full second before being pushed back, which
            # is plenty to yank someone out of a game - the owner saw exactly that on 2026-09-21.
            # Reading the log at 100 ms instead would mean re-reading a file that grows to megabytes,
            # so the two run at different rates.
            for ($tick = 0; $tick -lt 10 -and -not $client.HasExited; $tick++) {
                if ($userWindow -ne [IntPtr]::Zero) { [Nbidal18Focus]::KeepBehind($client.Id, $userWindow) }
                Start-Sleep -Milliseconds 100
            }
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                # Logged once the client is fully initialised, just before the title screen draws.
                if ((Read-SharedText $logPath) -match 'Sound engine started') { $reachedMenu = $true; break }
            }
            # No early exit on a mixin line: Mixin logs recoverable throwables during startup, and
            # aborting on the first one failed healthy clients. A fatal one kills the process, which
            # HasExited above already catches.
        }

        # "Sound engine started" is logged BEFORE the window settles: Minecraft finishes loading
        # resource packs and raises its window after it, so stopping here left a last grab
        # unopposed - the other half of what the owner saw. Keep chasing for a grace period, then
        # stop for good so that a -Hold client raised from the taskbar stays raised and nothing
        # fights the window once it is deliberately his.
        if ($userWindow -ne [IntPtr]::Zero -and -not $client.HasExited) {
            $settle = (Get-Date).AddSeconds($FocusGraceSeconds)
            while ((Get-Date) -lt $settle -and -not $client.HasExited) {
                [Nbidal18Focus]::KeepBehind($client.Id, $userWindow)
                Start-Sleep -Milliseconds 100
            }
            Write-Host ("focus     held for {0}s after start-up; the client is yours to raise now" -f $FocusGraceSeconds)
        }

        $log = if (Test-Path -LiteralPath $logPath -PathType Leaf) { Read-SharedText $logPath } else { '' }
        $lines = $log -split "`r?`n"
        $mixinLines = @($lines | Where-Object { $_ -match $mixinFailure })

        if (-not $reachedMenu) {
            $crash = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'crash-reports') -File -ErrorAction SilentlyContinue)
            # The loader's own refusal - a missing dependency, two jars with one id - is an ERROR
            # block in the log, not a mixin failure and not a crash report. Print it here, because the
            # staging directory is cleaned on exit and the log with it: on 2026-09-23 a missing
            # Fabric Language Kotlin cost a second seven-minute run just to read a line this could
            # have shown the first time.
            $errorLines = @($lines | Where-Object { $_ -match '/ERROR\]|^\s+- Mod .+ requires|^\s+- Install ' })
            $detail = if ($mixinLines.Count) { "`nMixin trouble, most likely the cause:`n" + (($mixinLines | Select-Object -First 10) -join "`n") }
            elseif ($errorLines.Count) { "`nThe log's ERROR lines:`n" + (($errorLines | Select-Object -First 12) -join "`n") }
            elseif ($crash.Count) { "`nCrash report: $($crash[0].FullName)" }
            else { "`nLog: $logPath" }
            throw "The client never reached the title screen within $BootTimeoutSeconds seconds.$detail"
        }
        Write-Host ("launch    title screen reached, {0} mods loaded" -f $stagedMods)

        # With -QuickPlay the title screen is not the finish line: the run exists to get into a world,
        # where block models bake, block entities load and HUD hooks run every frame. Wait for the
        # integrated server to admit the player, then leave it ticking for ten seconds so anything
        # that only fails in play has a chance to fail here. Added for the TreeChop port (v1.0.72):
        # its first in-world run was declared a pass at the title screen with the world never entered.
        if ($QuickPlay -or $QuickPlayServer) {
            $target = if ($QuickPlay) { $QuickPlay } else { $QuickPlayServer }
            $enteredWorld = $false
            while ((Get-Date) -lt $deadline -and -not $client.HasExited) {
                # Singleplayer logs vanilla's "joined the game"; on a server that chat line is whatever
                # the server's mods make of it (Sleeping Messages rewrites it), so the multiplayer
                # signal is the client's own "Joined server with ..." line from the play phase.
                if ((Read-SharedText $logPath) -match 'joined the game|Joined server with') { $enteredWorld = $true; break }
                Start-Sleep -Milliseconds 1000
            }
            if (-not $enteredWorld) {
                throw "Quick play never entered '$target' within $BootTimeoutSeconds seconds. Log: $logPath"
            }
            Start-Sleep -Seconds 10
            $log = Read-SharedText $logPath
            $lines = $log -split "`r?`n"
            $mixinLines = @($lines | Where-Object { $_ -match $mixinFailure })
            Write-Host ('world     entered {0} and ran for ten seconds' -f $target)
        }

        $failures = New-Object Collections.Generic.List[string]
        foreach ($check in $fatalPatterns) {
            $hits = @($lines | Where-Object { $_ -match $check.Pattern } | Select-Object -Unique)
            # An exemption is per-line and per-pattern, so the check stays live for everything else.
            if ($check.ContainsKey('Except')) {
                $hits = @($hits | Where-Object { $_ -notmatch $check.Except })
            }
            if ($hits.Count) {
                $failures.Add(("{0} ({1} lines) - {2}`n    {3}" -f $check.Name, $hits.Count, $check.Note,
                    (($hits | Select-Object -First 3) -join "`n    ")))
            }
        }
        foreach ($check in $requiredLines) {
            # A required line is only required when the mod that prints it was actually staged.
            # Without this the check is not "the bridge works" but "the bridge is installed", and it
            # fails any run that legitimately does not ship it - which is every step of the v2.0.0
            # rebuild, where the pack is built up one mod at a time from nothing.
            if ($check.ContainsKey('RequiresMod')) {
                $present = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File `
                        -Filter $check.RequiresMod -ErrorAction SilentlyContinue).Count
                if (-not $present) {
                    Write-Host ("skipped   {0} - {1} is not staged" -f $check.Name, $check.RequiresMod)
                    continue
                }
            }
            if ($log -notmatch $check.Pattern) {
                $failures.Add(("expected log line never appeared: {0} (/{1}/)" -f $check.Name, $check.Pattern))
            }
            else { Write-Host ("present   {0}" -f $check.Name) }
        }

        if ($mixinLines.Count) {
            Write-Warning ("Mixin logged and recovered from these. A mixin that quietly did not " +
                "apply is still a broken feature:`n" + (($mixinLines | Select-Object -First 10) -join "`n"))
        }
        if ($failures.Count) {
            # -Hold is for looking at something on screen, and it deliberately turns the resource
            # packs on, which is when most of these fire. Reporting them is useful; throwing would
            # kill the client the run exists to leave open.
            if ($Hold) {
                Write-Warning ("Faults in the log, reported rather than fatal because -Hold:`n`n" +
                    ($failures -join "`n`n"))
            }
            else {
                throw ("The client started, but the log contains faults that have shipped before:`n`n" +
                    ($failures -join "`n`n"))
            }
        }
        Write-Host ''
        Write-Host 'OK        title screen reached and no known-bad pattern in the log'
    }
    finally {
        if ($Hold -and -not $client.HasExited) {
            Write-Host ''
            Write-Host 'HOLD      the client is open and left running. Close it yourself when done.'
            Write-Host '          Create a creative world to look at containers - this directory is'
            Write-Host '          a throwaway and nothing in it reaches your real instance.'
        }
        elseif (-not $client.HasExited) { $client.Kill(); $client.WaitForExit(30000) | Out-Null }
        if (-not $Hold) { $client.Dispose() }
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $KeepGameDir -and -not $Hold -and
        $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
