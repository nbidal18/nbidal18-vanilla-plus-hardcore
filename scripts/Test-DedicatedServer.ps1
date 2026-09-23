<#
    Boots a throwaway copy of the server and checks it reaches "Done" without errors.

      scripts\Test-DedicatedServer.ps1
      scripts\Test-DedicatedServer.ps1 -Interactive     keep it up and drive the console

    **Nothing here touches the live server.** It reads the local mirror that Sync-ServerMirror -Pull
    writes, and itself writes only to a temp directory, on ports that do not clash, with a fresh
    world. It is safe to run while the real server is up.

    This line keeps no server payload in the release - the server exists only remotely - so the
    throwaway is assembled from what is actually installed there, with **everything this release
    would deploy overlaid on top**: the helper jar, the policy, and every other jar the server and
    the client pack share. That makes the question it answers the useful one: *will the server boot
    with what we are about to deploy to it?* Nothing has ever asked that.

    A fresh world is the point, not a shortcut. Generating one exercises every datapack the pack
    ships, which is how a broken one announces itself - v1.0.10 removed a recipe and left two
    advancements whose only criterion was unlocking it, and a dangling `recipe_unlocked` fails to
    load at worldgen time and nowhere else.

    What it cannot tell you: anything that needs a player to connect. Login, the integrity handshake
    and voice chat all need a real client.
#>
[CmdletBinding()]
param(
    [int] $MinecraftPort = 29150,
    [int] $VoicePort = 29151,
    [int] $BootTimeoutSeconds = 420,
    # The local mirror Sync-ServerMirror -Pull writes, not a mount: the `Y:` CloudMounter drive this
    # defaulted to expired, so the old default could only ever throw "A drive with the name 'Y'".
    [string] $DriveRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '_server-payload-cache'),
    # Jars this release puts on the server for the first time. Deploying one is a decision,
    # so proving it boots is opt-in rather than inferred from the jar's environment.
    [string[]] $AddMods = @(),
    # The throwaway world is normal survival, like the live one. -Hardcore makes it a hardcore
    # world, which is what exercises Hardcore Revive+'s gate the other way (v1.0.87: the jar is on
    # the server for both worlds and must be dormant on the normal one, active on the hardcore one).
    [switch] $Hardcore,
    [switch] $Interactive,
    [switch] $KeepGameDir,
    # Stage mods and config from this folder instead of the mirror, and skip the release overlay
    # entirely. Added 2026-09-23 for the clean 26.2 rebuild, which builds the server half up one mod
    # at a time in a folder that is not a release and has no integrity helper - the counterpart of
    # Test-ClientLaunch's -ClientSource. server.jar, libraries and versions still come from
    # -DriveRoot, because the Fabric launcher is not something the rebuild decides.
    #
    #   .\Test-DedicatedServer.ps1 -ServerSource ..\..\_rebuild-server `
    #       -DriveRoot ..\..\_server-payload-cache-hardcore\root
    [string] $ServerSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The server keeps latest.log open while it runs, so a plain read fails with a sharing violation.
function Read-SharedText([string] $path) {
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
$javaPath = Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-epsilon\bin\java.exe'

# The Vanilla+ mirror keeps the Fabric launcher (server.jar, libraries, versions) beside mods\ and
# config\; the Hardcore mirror keeps it under root\. Look in both, as Export-ServerInventory does -
# pointing this at root\ instead loses mods\ and config\, which sit one level up (2026-09-24).
$launcherRoot = $DriveRoot
if (-not (Test-Path -LiteralPath (Join-Path $DriveRoot 'server.jar')) -and
    (Test-Path -LiteralPath (Join-Path (Join-Path $DriveRoot 'root') 'server.jar'))) {
    $launcherRoot = Join-Path $DriveRoot 'root'
}

# A rebuild folder has no release behind it, so the release is required only when it is overlaid.
$required = @($DriveRoot, $javaPath, (Join-Path $launcherRoot 'server.jar'))
if ($ServerSource) {
    $ServerSource = [IO.Path]::GetFullPath((Join-Path $PWD.ProviderPath $ServerSource))
    $required += @($ServerSource, (Join-Path $ServerSource 'mods'))
}
else { $required += $release }
foreach ($item in $required) {
    if (-not (Test-Path -LiteralPath $item)) { throw "Missing input: $item" }
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('nbidal18-vp-server-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    # The world is deliberately not copied: it is 5 GB, and a fresh one is what exercises the
    # datapacks. libraries and versions are what the Fabric launcher loads; .fabric is a remap cache
    # the server rebuilds on its own, so it is skipped to keep the copy small.
    # With -ServerSource the launcher (server.jar, libraries, versions) still comes from the mirror
    # and the payload (mods, config) comes from the rebuild folder.
    $payloadRoot = if ($ServerSource) { $ServerSource } else { $DriveRoot }
    Write-Host ("copying   launcher from {0}" -f $launcherRoot)
    Write-Host ("copying   mods and config from {0}" -f $payloadRoot)
    foreach ($directory in @('mods', 'config', 'libraries', 'versions')) {
        $source = Join-Path $(if ($directory -in @('mods', 'config')) { $payloadRoot } else { $launcherRoot }) $directory
        if (Test-Path -LiteralPath $source) {
            robocopy $source (Join-Path $testRoot $directory) /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $directory ($LASTEXITCODE)" }
        }
    }
    Copy-Item -LiteralPath (Join-Path $launcherRoot 'server.jar') -Destination $testRoot -Force
    [IO.File]::WriteAllText((Join-Path $testRoot 'eula.txt'), "eula=true`n")

    if ($ServerSource) {
        Write-Host 'overlay   skipped - a rebuild folder has no release to overlay'
    }
    else {
    # Overlay what this release would deploy, so the boot proves the jar we are about to ship.
    $helpers = @(Get-ChildItem -LiteralPath (Join-Path $release '3. modpack\client\mods') -Filter 'nbidal18-integrity-*.jar')
    if ($helpers.Count -ne 1) { throw "Expected one integrity helper in the release, found $($helpers.Count)" }
    foreach ($stale in Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -Filter 'nbidal18-integrity-*.jar') {
        [IO.File]::Delete($stale.FullName)
    }
    Copy-Item -LiteralPath $helpers[0].FullName -Destination (Join-Path $testRoot 'mods') -Force
    Copy-Item -LiteralPath (Join-Path $release '4. server\nbidal18-integrity.properties') `
        -Destination (Join-Path $testRoot 'config') -Force
    # Every other jar the server and the release both carry, replaced with the release's copy. The
    # helper alone is not what a release changes: a fork whose datapack we edited boots here or it
    # does not, and a broken recipe or a dangling advancement fails at worldgen and nowhere else.
    # Overlaying only the helper meant this tested the previous release's datapacks.
    $releaseMods = Join-Path $release '3. modpack\client\mods'
    # Server-only first-party jars, never published to players (v1.0.73, the Mouse Wheelie server half).
    $releaseServerMods = Join-Path $release '4. server\mods'
    # A first-party jar the release no longer ships is retired by the deploy (Test-ServerDeployment's
    # rule), so it must not boot here either: two jars claiming one mod id is a loader error, not a
    # warning, and this test would fail a release that is fine. Scoped to nbidal18-* like the deploy;
    # a server-only jar that is not ours is never a candidate. Found when nbidal18-voxyworldgen went
    # 3.0.0 to 3.1.0 - the first rename of a server-side first-party jar since this check was written.
    $releaseJarNames = @{}
    foreach ($dir in @($releaseMods, $releaseServerMods)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($jar in @(Get-ChildItem -LiteralPath $dir -Filter *.jar -File)) { $releaseJarNames[$jar.Name] = $true }
    }
    foreach ($live in @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -Filter 'nbidal18-*.jar' -File)) {
        if ($live.Name -like 'nbidal18-integrity-*.jar' -or $releaseJarNames.ContainsKey($live.Name)) { continue }
        [IO.File]::Delete($live.FullName)
        Write-Host ("retired   {0} (superseded; the deploy removes it)" -f $live.Name)
    }
    $refreshed = 0
    foreach ($live in @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -Filter *.jar -File)) {
        if ($live.Name -like 'nbidal18-integrity-*.jar') { continue }
        $mirror = Join-Path $releaseMods $live.Name
        if (-not (Test-Path -LiteralPath $mirror -PathType Leaf)) { $mirror = Join-Path $releaseServerMods $live.Name }
        if (-not (Test-Path -LiteralPath $mirror -PathType Leaf)) { continue }
        if ((Get-FileHash -LiteralPath $live.FullName -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $mirror -Algorithm SHA256).Hash) { continue }
        [IO.File]::WriteAllBytes($live.FullName, [IO.File]::ReadAllBytes($mirror))
        Write-Host ("overlaid  {0} (differed from the live server's copy)" -f $live.Name)
        $refreshed++
    }
    # A jar the release adds that the server does not have yet. Deploy-LiveServer deliberately
    # refuses to add one - a new server-side mod is a decision, not a sync - and the same holds
    # here, so these are named rather than detected. The jar's own `environment` is not the test:
    # most of this pack's client-only mods declare "*" as well, and trusting it put Iris Extension
    # on a server with no Iris, which fails resolution before anything else is proven.
    $addedNames = @()
    foreach ($name in $AddMods) {
        $candidate = Join-Path $releaseMods $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $candidate = Join-Path $releaseServerMods $name }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "-AddMods named $name, which is not in the release's mods folder"
        }
        Copy-Item -LiteralPath $candidate -Destination (Join-Path $testRoot 'mods') -Force
        $addedNames += $name
        Write-Host ("added     {0} (named by -AddMods, absent from the server)" -f $name)
    }
    Write-Host ("overlaid  {0}, this release's policy and {1} other jar(s); added {2} named jar(s)" -f $helpers[0].Name, $refreshed, $addedNames.Count)
    }

    # A properties file of our own rather than the live one: no whitelist, no ops, its own ports and
    # its own world, so nothing here can collide with the real server or need its player files.
    $properties = @(
        "server-port=$MinecraftPort",
        'level-name=smoketest',
        'online-mode=false',
        'white-list=false',
        'enforce-whitelist=false',
        'max-players=1',
        'difficulty=hard',
        ('hardcore=' + $(if ($Hardcore) { 'true' } else { 'false' })),
        'view-distance=4',
        'simulation-distance=4',
        # Server Pause sleeps the server thread once nobody is connected, and nothing here ever has
        # a player. Left on, the boot check would be racing a sleeping server.
        'pause-when-empty-seconds=0',
        'motd=nbidal18 smoke test',
        'sync-chunk-writes=false'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $testRoot 'server.properties'), $properties + "`n")

    $voicePath = Join-Path $testRoot 'config\voicechat\voicechat-server.properties'
    if (Test-Path -LiteralPath $voicePath) {
        $voiceText = [regex]::Replace([IO.File]::ReadAllText($voicePath), '(?m)^port=.*$', "port=$VoicePort")
        [IO.File]::WriteAllText($voicePath, $voiceText)
    }

    # generationRadius is 512 on the live server, which is the whole point there and pure cost here:
    # a fresh world would spend the entire timeout generating terrain nobody looks at.
    $voxyPath = Join-Path $testRoot 'config\voxyworldgenv2.json'
    if (Test-Path -LiteralPath $voxyPath) {
        $voxy = [IO.File]::ReadAllText($voxyPath)
        [IO.File]::WriteAllText($voxyPath, [regex]::Replace($voxy, '"generationRadius"\s*:\s*\d+', '"generationRadius": 4'))
    }

    $serverJar = Join-Path $testRoot 'server.jar'
    Push-Location $testRoot
    try {
        if ($Interactive) {
            & $javaPath -Xms1G -Xmx3G -jar $serverJar nogui
            if ($LASTEXITCODE -ne 0) { throw "The server exited with code $LASTEXITCODE" }
            return
        }

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $javaPath
        $startInfo.Arguments = "-Xms1G -Xmx3G -jar `"$serverJar`" nogui"
        $startInfo.WorkingDirectory = $testRoot
        $startInfo.UseShellExecute = $false
        $server = [Diagnostics.Process]::Start($startInfo)
        $logPath = Join-Path $testRoot 'logs\latest.log'
        try {
            Write-Host ("booting   on port {0}, fresh world, up to {1}s" -f $MinecraftPort, $BootTimeoutSeconds)
            $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
            $booted = $false
            while ((Get-Date) -lt $deadline -and -not $server.HasExited) {
                if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                    if ((Read-SharedText $logPath) -match '(?m)^\[[^\]]+\] \[Server thread/INFO\]: Done \(') {
                        $booted = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 500
            }
            if (-not $booted) {
                $tail = if (Test-Path -LiteralPath $logPath) {
                    "`nLast lines:`n" + (((Read-SharedText $logPath) -split "`r?`n" | Select-Object -Last 15) -join "`n")
                }
                else { '' }
                throw "The server never finished loading within $BootTimeoutSeconds seconds.$tail"
            }
            Write-Host 'booted    reached "Done"'
            # SERVER_STARTED handlers log in the tick after "Done" (the far-terrain pacer, the
            # revive gate's active/dormant line); killed in the same instant they never appear in
            # the log this script keeps, and a check that reads them is a coin toss.
            Start-Sleep -Seconds 3
        }
        finally {
            # Killed rather than stopped through the console: the Fabric launcher does not forward
            # redirected stdin, so a 'stop' is never read. The world is a throwaway.
            if (-not $server.HasExited) { $server.Kill(); $server.WaitForExit(30000) | Out-Null }
            $server.Dispose()
        }

        # Errors this mod set logs on a healthy boot. Each is here because it is noise, not because
        # it is convenient - an allowlist that grows without a reason attached is how a check dies.
        $benign = @(
            # C2ME's own worldgen safety diagnostic. It fires in bursts on a fresh world and is a
            # warning about a vanilla feature reading a neighbour chunk, not a failure.
            'Detected unsafe terrain read during worldgen',
            'No data fixer registered for'
        )
        # -ServerSource means a rebuild folder, which by definition has no published channel and so
        # no integrity policy for the helper to read. The helper says so, once, at ERROR level, and
        # then correctly leaves transition mode open and the query disabled. Against a release this
        # same line means the policy is missing or corrupt and must still fail the test, so the
        # exemption is scoped to rebuild runs rather than added to the list above.
        if ($ServerSource) {
            $benign += 'Integrity server policy could not be read'
        }

        $lines = (Read-SharedText $logPath) -split "`r?`n"

        # BCLib patches an existing world's level.dat on boot, and it does so before the server has
        # created one. Against a world that already exists - every real server - it reads the file
        # and patches it. Against this harness's deliberately fresh world there is nothing to read,
        # so it throws, logs three ERROR lines and carries on booting.
        #
        # Allowed only when the stack trace proves that is what happened. A genuine patch failure on
        # a real level.dat raises the same three lines without the missing-file exception, and still
        # fails this test.
        if ($lines | Where-Object { $_ -match 'NoSuchFileException: .*level\.dat' }) {
            $benign += @(
                'Failed fixing Level-Data',
                'There were Errors while fixing the Level',
                # Same cause, one stage earlier: no level.dat means no world preset to read back.
                'WorldPresetInfoRegistry: Registry not read'
            )
        }

        $errors = @($lines | Where-Object { $_ -match '/ERROR\]' } | Where-Object {
                $line = $_
                -not ($benign | Where-Object { $line -match [regex]::Escape($_) })
            })
        if ($errors.Count) {
            throw ("The server booted but logged errors:`n" + (($errors | Select-Object -First 12) -join "`n"))
        }

        # The datapack proof. Generating a world parses every recipe and advancement the pack ships,
        # so these counts are what says the datapacks are intact - a dangling recipe_unlocked
        # advancement fails here and nowhere else.
        $recipes = [regex]::Match(($lines -join "`n"), 'Loaded (\d+) recipes')
        $advancements = [regex]::Match(($lines -join "`n"), 'Loaded (\d+) advancements')
        if (-not $recipes.Success -or [int] $recipes.Groups[1].Value -eq 0) {
            throw 'The server never reported loading any recipes - the datapacks did not parse.'
        }
        if (-not $advancements.Success -or [int] $advancements.Groups[1].Value -eq 0) {
            throw 'The server never reported loading any advancements - the datapacks did not parse.'
        }

        $mods = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -Filter *.jar).Count
        Write-Host ''
        Write-Host ("OK        {0} mods, fresh world, {1} recipes and {2} advancements loaded, no unexpected errors" -f `
                $mods, $recipes.Groups[1].Value, $advancements.Groups[1].Value)
    }
    finally { Pop-Location }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $KeepGameDir -and $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The server is killed rather than stopped, so it exits non-zero and PowerShell keeps that in
# $LASTEXITCODE. Reaching here means every check passed, so say so explicitly - otherwise a caller
# gating on the exit code sees a failure that did not happen.
exit 0
