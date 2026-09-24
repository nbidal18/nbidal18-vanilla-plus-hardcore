<#
    Runs the real updater against the local build and checks what it produced.

      scripts\Test-LocalSync.ps1
      scripts\Test-LocalSync.ps1 -KeepGameDir     leave the instance for inspection

    `site\` is served on a loopback port and the updater is pointed at it, so this tests the release
    **before** it is published rather than after. Nothing touches the real instance, the real server
    or the channel.

    Every other check looks at one end of the pipe. `Build-Release` proves the build is coherent and
    `Verify-PublishedChannel` proves the channel serves it; only this proves the thing in between -
    that the updater, given that channel, produces the instance the manifest describes.

    The assertions, and why each is here:

      installs      every managed file arrives with the hash the manifest records
      preserves     a `player`-class file the updater must never restore is still published once
      pins          every property rule holds after the sync
      seeds         a declared player-file row is written, which is how a shipped default reaches an
                    existing instance at all
      no intruders  nothing appears under an exact root that the manifest does not name
      idempotent    a second sync changes nothing. This is the one that would have caught the
                    .gitattributes byte rewrite as what it was - files redownloading on every
                    launch, for ever, without converging
#>
[CmdletBinding()]
param(
    [int] $Port = 29180,
    [switch] $KeepGameDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What this pack line expects, read from data rather than written here, so this script file stays
# identical between nbidal18-vanilla-plus and nbidal18-vanilla-plus-hardcore - the same reason
# RELEASE-PREFIX.txt and PACK-NAME.txt exist. Until 2026-09-23 the three addresses, the seed marker
# and the config probe were spelled out below, and all of them were Vanilla+ facts: the hardcore
# line ships one server, seeds nothing, and does not have Immersive Aircraft to probe.
$expectPath = Join-Path $PSScriptRoot 'local-sync-expectations.json'
if (-not (Test-Path -LiteralPath $expectPath)) {
    throw "No local-sync-expectations.json beside the scripts ($expectPath). It holds this pack line's expected server list, its ServerListSeed if it has one, and its config probe."
}
$expect = Get-Content -LiteralPath $expectPath -Raw | ConvertFrom-Json
$expectedServers = @($expect.expectedServers)
if (-not $expectedServers.Count) { throw 'local-sync-expectations.json lists no expectedServers.' }
$seed = $expect.serverListSeed
$configProbe = $expect.configProbe
$worldFolderAddress = $expect.worldFolderAddress
$worldFolderPort = $expect.worldFolderPort

$repo = Split-Path -Parent $PSScriptRoot
$clientZip = (Get-Content -LiteralPath (Join-Path $repo 'CLIENT-ZIP.txt') -Raw).Trim()
if (-not $clientZip.EndsWith('.zip')) { throw "CLIENT-ZIP.txt is '$clientZip'; it must name a .zip." }
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
$site = Join-Path $repo 'site'
# `packwiz serve` below opens a listening socket, and packwiz has no flag to bind loopback only, so
# Windows Firewall prompts the first time it sees each path. This script is where that prompt
# actually came from - see Resolve-PackwizTool.ps1 for the full account and why the binary is run
# from one stable location instead of from the release folder.
. (Join-Path $PSScriptRoot 'Resolve-PackwizTool.ps1')
$packwiz = Resolve-PackwizTool -Release $release
$javaPath = Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-epsilon\bin\java.exe'

foreach ($required in @($site, $packwiz, $javaPath, (Join-Path $site 'pack.toml'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing input: $required" }
}

function Get-Sha([string] $path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NormalizedSha([string] $path) {
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

# Property rules are one key inside an otherwise player-owned file, so read that key the way the
# updater does rather than hashing the file.
function Get-PropertyValue([string] $path, [string] $key) {
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOfAny(@(':', '='))
        if ($separator -lt 1) { continue }
        if ($trimmed.Substring(0, $separator).Trim() -ceq $key) {
            return $trimmed.Substring($separator + 1).Trim()
        }
    }
    return $null
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('nbidal18-vp-sync-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$minecraft = Join-Path $testRoot 'minecraft'
$server = $null
$failures = [Collections.Generic.List[string]]::new()

function Assert([bool] $condition, [string] $message) {
    if (-not $condition) { $failures.Add($message) }
}

try {
    New-Item -ItemType Directory -Path $minecraft -Force | Out-Null

    $server = Start-Process -FilePath $packwiz -ArgumentList "serve --basic --port $Port" `
        -WorkingDirectory $site -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $testRoot 'serve.log') `
        -RedirectStandardError (Join-Path $testRoot 'serve.err')
    $ready = $false
    foreach ($attempt in 1..60) {
        if ($server.HasExited) { throw "The local server exited: $([IO.File]::ReadAllText((Join-Path $testRoot 'serve.err')))" }
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:$Port/pack.toml" -UseBasicParsing -TimeoutSec 1 | Out-Null
            $ready = $true; break
        }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw "The local server never answered on port $Port" }
    Write-Host ("serving   site\\ on http://127.0.0.1:{0}" -f $Port)

    # The four tool jars a fresh instance starts with, exactly as the client ZIP delivers them.
    # Seeded from nbidal18-client.zip rather than by picking files, because that is literally what a
    # player imports - and it means this also proves the ZIP carries what a first install needs.
    # The .next copies matter: the supervisor promotes them before running anything and throws when
    # one is absent. An earlier draft copied only the four live jars and failed exactly there.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $site $clientZip
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "Missing client ZIP: $zipPath" }
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $seeded = 0
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notlike 'minecraft/*' -or $entry.FullName.EndsWith('/')) { continue }
            $target = Join-Path $minecraft $entry.FullName.Substring('minecraft/'.Length).Replace('/', [IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            $seeded++
        }
    }
    finally { $zip.Dispose() }
    Write-Host ("seeded    {0} files from {1}" -f $seeded, $clientZip)

    # The ZIP's servers.dat already carries the CURRENT hardcore address, so on a fresh install the
    # server-list seed has nothing to do and this would never prove it works. Give the instance the
    # list an existing player actually has - the hardcore server at its OLD address - so the seed has
    # to perform the v1.0.106 move, which is the path that can go wrong. Appending instead of
    # rewriting would leave two hardcore entries, and the assertions after the sync catch exactly
    # that: the new address present, the old one gone, and one hardcore entry rather than two.
    # An `added` seed (previous = null) has no old address: the instance is given the list WITHOUT
    # the entry, as an instance imported before the entry existed has it, so the seed has to append.
    $serverList = Join-Path $minecraft 'servers.dat'
    if ($seed -and (Test-Path -LiteralPath $serverList -PathType Leaf)) {
        $rolled = & python (Join-Path $PSScriptRoot 'Edit-ServerList.py') $serverList $serverList remove $seed.current
        if ($LASTEXITCODE -ne 0) { throw "Edit-ServerList.py failed: $rolled" }
        if ($seed.previous) {
            $rolled = & python (Join-Path $PSScriptRoot 'Edit-ServerList.py') $serverList $serverList add $seed.name $seed.previous
            if ($LASTEXITCODE -ne 0) { throw "Edit-ServerList.py failed: $rolled" }
            Write-Host ("rolled    servers.dat back to {0}, so the updater's seed has to move it" -f $seed.previous)
        }
        else {
            Write-Host ("rolled    servers.dat back to without {0}, so the updater's seed has to add it" -f $seed.current)
        }
    }
    elseif (-not $seed) {
        Write-Host 'seeds     this line ships no ServerListSeed, so the shipped servers.dat is checked as delivered'
    }

    $env:INST_MC_DIR = $minecraft
    $env:NBIDAL18_PACK_URL = "http://127.0.0.1:$Port/pack.toml"
    $env:NBIDAL18_MANIFEST_URL = "http://127.0.0.1:$Port/sync-manifest.json"
    $env:NBIDAL18_HEADLESS_TEST = '1'

    function Invoke-Sync([string] $label) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & $javaPath -jar (Join-Path $minecraft 'nbidal18-packwiz-sync.jar') 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
        if ($code -ne 0) {
            throw ("$label exited with $code`n" + (($output | Select-Object -Last 15) -join "`n"))
        }
        Write-Host ("{0,-9} completed" -f $label)
        return $output
    }

    # The retired-directory sweep deletes whole trees on a player's machine, so it is checked here
    # rather than trusted.
    #
    # **Rewritten for v1.0.109, when the sweep stopped being wholesale.** It used to take `.voxy` and
    # `xaero/world-map` entire, and this checked exactly that. Only the End was regenerated on
    # 2026-09-22, so only the End's caches are stale - and the owner's Voxy store is 40 GB, with one
    # player on a connection poor enough that re-streaming it was the reason the far-terrain work
    # exists. So the sweep now names the End's Xaero folder per server, Voxy is handled inside the
    # game by nbidal18-voxyworldgen's declared ledger resets, and this asserts the new shape:
    # the End's images go, the overworld's and the Nether's stay, Voxy is left alone entirely, and
    # the waypoints - the single Xaero feature this pack kept - survive as they always had to.
    $sep = [IO.Path]::DirectorySeparatorChar
    $keptVoxy = Join-Path $minecraft (@('.voxy', 'saves', ($worldFolderAddress + '_' + $worldFolderPort)) -join $sep)
    $doomedMap = Join-Path $minecraft (@('xaero', 'world-map', ('Multiplayer_' + $worldFolderAddress), 'DIM1') -join $sep)
    $keptOverworldMap = Join-Path $minecraft (@('xaero', 'world-map', ('Multiplayer_' + $worldFolderAddress), 'null') -join $sep)
    $keptWaypoints = Join-Path $minecraft (@('xaero', 'minimap', 'Multiplayer_test') -join $sep)
    foreach ($dir in @($keptVoxy, $doomedMap, $keptOverworldMap, $keptWaypoints)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $keptVoxy 'lod.bin'), 'cache')
    [IO.File]::WriteAllText((Join-Path $doomedMap 'region.zip'), 'cache')
    [IO.File]::WriteAllText((Join-Path $keptOverworldMap 'region.zip'), 'cache')
    $waypointFile = Join-Path $keptWaypoints 'waypoints.txt'
    [IO.File]::WriteAllText($waypointFile, "waypoint:Keep me:K:1:2:3")

    # Every marker the sweep has ever written, planted before the sync. A fresh instance cannot show
    # the failure that matters: these caches describe terrain, so they go stale every time the world
    # is regenerated, and the sweep is one-time per token. v1.0.23 cleared the world a second time
    # without bumping the token, so the sweep did nothing on every instance that already carried
    # v1.0.20's marker - which was all of them. Planting them here means the release either brings a
    # token no instance has seen or this fails.
    $stateDir = Join-Path $minecraft '.nbidal18-packwiz'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    foreach ($old in @('retired-files-v1020', 'retired-files-v1060', 'retired-files-v1061')) {
        [IO.File]::WriteAllText((Join-Path $stateDir ("applied-" + $old)), $old)
    }

    # "Published once, preserved forever" starts counting at the FIRST delivery, so a player-class
    # file that already exists is still replaced the one time the pack starts publishing it. That is
    # what makes the aircraft keybind fix reach people who are already playing, and it is worth
    # pinning down: the obvious reading - that an existing file is never touched - would mean the
    # fix silently missed every current player, and a fresh instance cannot tell the two apart.
    $probeFile = $null
    if ($configProbe) {
        $probeFile = Join-Path $minecraft ($configProbe.path -replace '/', [string][IO.Path]::DirectorySeparatorChar)
        $probeDir = Split-Path -Parent $probeFile
        if (-not (Test-Path -LiteralPath $probeDir)) { New-Item -ItemType Directory -Path $probeDir -Force | Out-Null }
        [IO.File]::WriteAllText($probeFile, ($configProbe.stub -replace "`r`n", "`n"))
    }

    $firstSync = Invoke-Sync 'sync 1'

    Assert (-not (Test-Path -LiteralPath $doomedMap)) `
        "the retired-directory sweep left Xaero's End map images behind"
    Assert (Test-Path -LiteralPath (Join-Path $keptOverworldMap 'region.zip')) `
        "the sweep took Xaero's overworld map images too - only the End was regenerated"
    Assert (Test-Path -LiteralPath (Join-Path $keptVoxy 'lod.bin')) `
        'the sweep deleted the Voxy store - 40 GB for every player, and the End alone is stale; that is the game-side ledger reset''s job now'
    Assert (Test-Path -LiteralPath $waypointFile) `
        'the retired-directory sweep deleted the Xaero waypoints, which it must never touch'

    # Deleting several gigabytes silently reads as a hang, so the sweep has to say what it is doing
    # by name. Asserted rather than assumed: a status line that quietly stops being emitted would
    # otherwise only show up as a player watching a frozen updater.
    if ($configProbe) {
        $probeAfter = [IO.File]::ReadAllText($probeFile)
        Assert (-not ($probeAfter -match $configProbe.mustNotMatch)) $configProbe.failIfStale
        Assert ($probeAfter -match $configProbe.mustMatch) $configProbe.failIfMissing
        if (($probeAfter -match $configProbe.mustMatch) -and -not ($probeAfter -match $configProbe.mustNotMatch)) {
            Write-Host ("probe     {0}" -f $configProbe.ok)
        }
    }

    $swept = @($firstSync | Where-Object { $_ -match 'Clearing ' })
    Assert ($swept.Count -gt 0) `
        'the sweep removed the caches without announcing it - the updater would look frozen'
    if ($swept.Count) { Write-Host ("retired   {0}" -f ($swept[0] -replace '^\[nbidal18 packwiz\] ', '')) }
    if ((Test-Path -LiteralPath $waypointFile) -and (Test-Path -LiteralPath (Join-Path $keptVoxy 'lod.bin'))) {
        Write-Host 'retired   the End map images only; Voxy and the waypoints untouched'
    }

    $manifest = [IO.File]::ReadAllText((Join-Path $site 'sync-manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $normalized = @{}
    foreach ($entry in $manifest.normalizedTextFiles) { $normalized[$entry.path] = $entry.sha256 }
    $localAllowed = @{}
    foreach ($path in $manifest.localAllowed) { $localAllowed[$path] = $true }

    # A player-class file that a declared seed changed on this fresh install legitimately differs
    # from the published copy: the master must not carry the seeded value (changing it would
    # re-deliver the file over every player's own copy - v1.0.74's shader settings), so the seed
    # is the only place the value lives. The updater records which file each seed edited in its
    # marker; those paths are allowed to differ, and only those.
    $seeded = @{}
    $stateRoot = Join-Path $minecraft '.nbidal18-packwiz'
    if (Test-Path -LiteralPath $stateRoot) {
        foreach ($marker in Get-ChildItem -LiteralPath $stateRoot -Filter 'applied-*' -File) {
            $lines = @([IO.File]::ReadAllLines($marker.FullName))
            if ($lines.Count -ge 3 -and $lines[2] -eq 'changed') { $seeded[$lines[1]] = $lines[0] }
        }
    }

    # installs
    $missing = 0; $wrong = 0
    foreach ($entry in $manifest.files) {
        $local = Join-Path $minecraft $entry.path.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { $missing++; continue }
        $expected = if ($normalized.ContainsKey($entry.path)) { $normalized[$entry.path] } else { $entry.sha256 }
        $actual = if ($normalized.ContainsKey($entry.path)) { Get-NormalizedSha $local } else { Get-Sha $local }
        if ($actual -ne $expected -and $localAllowed.ContainsKey($entry.path) -and $seeded.ContainsKey($entry.path)) {
            Write-Host ("seeded    {0} differs from the published copy by design (seed {1})" -f $entry.path, $seeded[$entry.path])
            continue
        }
        if ($actual -ne $expected) {
            $wrong++
            # Name it. A count alone sent v1.0.74's build hunting through 299 files for the one.
            Write-Host ("mismatch  {0}: manifest {1}, installed {2}" -f $entry.path, $expected.Substring(0, 12), $actual.Substring(0, 12))
        }
    }
    Assert ($missing -eq 0) "$missing managed files were not installed"
    Assert ($wrong -eq 0) "$wrong installed files do not match the hash the manifest records"
    Write-Host ("installed {0} managed files, {1} missing, {2} mismatched" -f $manifest.files.Count, $missing, $wrong)

    # preserves - a player-class file that is ALSO published must arrive on a first install. Being in
    # localAllowed alone does not imply publication: it means "never police this", and a file the
    # owning mod writes for itself is allowed without being shipped.
    $published = @{}
    foreach ($entry in $manifest.files) { $published[$entry.path] = $true }
    $shouldExist = @($manifest.localAllowed | Where-Object { $published.ContainsKey($_) })
    $preservedMissing = @($shouldExist | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $minecraft $_.Replace('/', '\')) -PathType Leaf)
        })
    Assert ($preservedMissing.Count -eq 0) ("player-class files not published on a first install: " + ($preservedMissing -join ', '))

    # Every localAllowed path must name a file that is either published or already on disk. The
    # updater matches this list exactly, so a path that names nothing is a file being enforced when
    # it should be preserved - which is how a mojibake section sign went unnoticed: the E-LITE shader
    # settings file was policed, and any player changing a shader option would have been refused at
    # login.
    $orphanAllowed = @($manifest.localAllowed | Where-Object {
            -not $published.ContainsKey($_) -and
            -not (Test-Path -LiteralPath (Join-Path $minecraft $_.Replace('/', '\')) -PathType Leaf)
        })
    Assert ($orphanAllowed.Count -eq 0) ("localAllowed names paths that are neither published nor present - look for an encoding mismatch: " + ($orphanAllowed -join ', '))
    Write-Host ("preserved {0} of {1} player-class paths, {2} orphaned" -f `
            ($shouldExist.Count - $preservedMissing.Count), $manifest.localAllowed.Count, $orphanAllowed.Count)

    # pins
    $badPins = [Collections.Generic.List[string]]::new()
    foreach ($rule in $manifest.propertyRules) {
        $target = Join-Path $minecraft $rule.path.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $badPins.Add("$($rule.path) missing"); continue }
        $value = Get-PropertyValue $target $rule.key
        if ($value -ne $rule.value) { $badPins.Add("$($rule.path)#$($rule.key) = $value, expected $($rule.value)") }
    }
    Assert ($badPins.Count -eq 0) ("property rules not applied: " + ($badPins -join '; '))
    Write-Host ("pinned    {0} property rules hold" -f $manifest.propertyRules.Count)

    # seeds - a flat file the updater creates from nothing when it is absent
    $options = Join-Path $minecraft 'options.txt'
    Assert (Test-Path -LiteralPath $options -PathType Leaf) 'the seed did not create options.txt'
    if (Test-Path -LiteralPath $options -PathType Leaf) {
        $packsRow = Get-PropertyValue $options 'resourcePacks'
        Assert ($null -ne $packsRow -and $packsRow.StartsWith('[')) 'the resourcePacks row was not seeded'
        # v1.0.97 adds Cactus Zombies to the list the earlier seeds wrote instead of writing the list
        # again, so a pack a player switched off stays off. It has to land after Fresh Animations'
        # packs, or their own zombie texture draws over it.
        $cactus = '"file/nbidal18-Cactus-Zombies-1.0.zip"'
        Assert ($null -ne $packsRow -and $packsRow.Contains($cactus)) 'the Cactus Zombies seed did not add the pack to resourcePacks'
        Assert ($null -ne $packsRow -and $packsRow.IndexOf($cactus) -gt $packsRow.LastIndexOf('"file/FA+')) 'Cactus Zombies is listed before a Fresh Animations pack, so it would be drawn over'
        Write-Host 'seeded    options.txt carries the declared rows'
    }
    # Both servers in the multiplayer list: the address strings are plain UTF-8 inside the NBT.
    $serverList = Join-Path $minecraft 'servers.dat'
    Assert (Test-Path -LiteralPath $serverList -PathType Leaf) 'servers.dat is missing after the sync'
    $serverBytes = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($serverList))
    foreach ($address in $expectedServers) {
        Assert ($serverBytes.Contains($address)) "servers.dat does not list $address after the sync"
    }
    if ($seed) {
        # The move's whole point: the dead address is gone rather than sitting beside the new one.
        if ($seed.previous) {
            Assert (-not $serverBytes.Contains($seed.previous)) `
                "servers.dat still lists the previous hardcore address $($seed.previous) after the sync"
        }
        $serverMarker = Join-Path $minecraft ".nbidal18-packwiz\$($seed.marker)"
        Assert ((Test-Path -LiteralPath $serverMarker) -and (([IO.File]::ReadAllLines($serverMarker))[2] -eq 'changed')) 'the server-list seed did not report moving the hardcore server'
    }
    # The file the updater wrote has to be NBT the game can read, not just bytes that contain the
    # addresses: Edit-ServerList.py parses every tag, refuses trailing bytes, and finds the entry.
    # Removing one known address must take exactly one entry - two would mean a seed appended a
    # duplicate instead of rewriting the one that was there.
    $probeAddress = $expectedServers[-1]
    $parsed = & python (Join-Path $PSScriptRoot 'Edit-ServerList.py') $serverList (Join-Path $testRoot 'servers-parsed.dat') remove $probeAddress
    Assert ($LASTEXITCODE -eq 0 -and (($parsed -join "`n") -match 'removed\s+1 entries')) "the updater's servers.dat did not parse with exactly one $probeAddress entry: $parsed"
    Write-Host ("seeded    servers.dat lists {0} server(s) as valid NBT" -f $expectedServers.Count)

    # no intruders
    $managed = @{}
    foreach ($entry in $manifest.files) { $managed[$entry.path.ToLowerInvariant()] = $true }
    foreach ($path in $manifest.localAllowed) { $managed[$path.ToLowerInvariant()] = $true }
    $extra = [Collections.Generic.List[string]]::new()
    foreach ($root in $manifest.exactRoots) {
        if ($manifest.extraTolerantRoots -contains $root) { continue }
        $rootPath = Join-Path $minecraft $root
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force) {
            $relative = $file.FullName.Substring($minecraft.Length).TrimStart('\').Replace('\', '/')
            if (-not $managed.ContainsKey($relative.ToLowerInvariant())) { $extra.Add($relative) }
        }
    }
    Assert ($extra.Count -eq 0) ("files under an exact root that the manifest does not name: " + ($extra -join ', '))
    Write-Host ("intruders {0}" -f $extra.Count)

    # idempotent
    $before = @{}
    foreach ($entry in $manifest.files) {
        $local = Join-Path $minecraft $entry.path.Replace('/', '\')
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            $before[$entry.path] = (Get-Item -LiteralPath $local).LastWriteTimeUtc
        }
    }
    Invoke-Sync 'sync 2' | Out-Null
    $rewritten = [Collections.Generic.List[string]]::new()
    foreach ($path in $before.Keys) {
        $local = Join-Path $minecraft $path.Replace('/', '\')
        if ((Test-Path -LiteralPath $local -PathType Leaf) -and
            (Get-Item -LiteralPath $local).LastWriteTimeUtc -ne $before[$path]) {
            $rewritten.Add($path)
        }
    }
    Assert ($rewritten.Count -eq 0) ("a second sync rewrote {0} files that had not changed - they would redownload on every launch: {1}" -f `
            $rewritten.Count, (($rewritten | Select-Object -First 8) -join ', '))
    Write-Host ("idempotent {0} files rewritten by a second sync" -f $rewritten.Count)

    $stamp = Join-Path $minecraft '.nbidal18-packwiz\last-successful-manifest.json'
    Assert (Test-Path -LiteralPath $stamp -PathType Leaf) 'no successful-sync stamp was written'
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        $installed = ([IO.File]::ReadAllText($stamp, [Text.Encoding]::UTF8) | ConvertFrom-Json).packVersion
        Assert ($installed -eq $manifest.packVersion) "the stamp says $installed but the build is $($manifest.packVersion)"
    }

    if ($failures.Count) { throw ("Local sync check failed:`n  " + ($failures -join "`n  ")) }
    Write-Host ''
    Write-Host ("OK        the updater installs, preserves, pins, seeds and converges on v{0}" -f $version)
}
finally {
    if ($server -and -not $server.HasExited) { $server.Kill(); $server.WaitForExit(10000) | Out-Null }
    if ($server) { $server.Dispose() }
    Remove-Item Env:INST_MC_DIR, Env:NBIDAL18_PACK_URL, Env:NBIDAL18_MANIFEST_URL, Env:NBIDAL18_HEADLESS_TEST -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $KeepGameDir -and $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
