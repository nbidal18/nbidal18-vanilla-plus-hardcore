<#
    Works out what this release changes on the server, stages it, and proves it - without touching
    the live server at all beyond reading it.

      scripts\Test-ServerDeployment.ps1
      scripts\Test-ServerDeployment.ps1 -AddMods carryon-fabric-26.2-2.11.0.jar -Config carryon-common.json
      scripts\Test-ServerDeployment.ps1 -DriveRoot C:\scratch\mirror    rehearse, never deployable

    **Run this while the server is still up and players are still on it.** Everything here is local
    or read-only: the pull downloads, the plan compares hashes, the staging writes into the local
    mirror, and the verification re-reads what it wrote. None of it needs an outage, and the pull
    alone moves 169 MB - measured at 48.7s against 1.0s for the two files a deploy has to re-read
    once the server has actually stopped.

    That is why this is a separate script. All of it used to live in Deploy-LiveServer, which meant
    the only way to run it was to run the deploy - so it ran after the server was stopped, and the
    outage carried a 169 MB transfer nobody was waiting on. v1.0.38 was the release that made that
    obvious. Deploy-LiveServer now does nothing but send what this proved and check that it landed.

    It ends by writing a **deployment plan** to `.nbidal18-deploy-plan.json` in the mirror: the exact
    list of files to send, the exact list to delete, and the SHA-256 each staged file must still have
    when the deploy runs. Deploy-LiveServer refuses to send anything that is not in that plan, and
    refuses a plan whose version, digest or mirror does not match what it is being asked to deploy.

    What it decides, and why each decision is named rather than inferred:

      the helper jar and the integrity policy come from the release and are not optional
      the MOTD is set from the version, because it was forgotten on v1.0.1 and v1.0.2
      **shared jars** - any jar the server and the client pack both carry - are compared by hash and
      re-deployed when they differ. This is the quiet one: the Vanilla Refresh fork ran two commits
      behind and silently wrote its own defaults over 22 settings, and the Hardcore Revive fork kept
      serving a recipe removed a release earlier. Both were found by the owner, not by a check
      **-AddMods** names a jar the server does not have yet. Most of the client pack is client-only
      and nothing here can tell which of it is not, so this stays a decision - but one written down
      here rather than dragged across in a file manager afterwards
      **-RemoveMods** names a third-party jar to take off the server. The mirror image of -AddMods,
      and named for the same reason
      **-Config** names a config file to take from the release's client copy. Named rather than
      synced, because most config genuinely differs: c2me.toml carries the CPU's own parallelism.
      But nothing deployed config at all until v1.0.29, and two files paid for it - sparsestructures
      sat at the mod's default while the pack shipped 5, and bcc-common.toml said v1.0.0 for
      twenty-two releases

    Backups of everything it is about to overwrite go to `.nbidal18-deploy-backups\` in the mirror,
    and every one is diffed against the file it copied. SFTP here serves stale content - to
    Copy-Item as well as to Bash - and a backup that silently predates the live file is not a
    rollback. `server.properties` and the policy are backed up here too, but the deploy re-reads
    both after the shutdown, because the server rewrites them as it stops.
#>
[CmdletBinding()]
param(
    [string[]] $AddMods = @(),
    [string[]] $Config = @(),
    # server.properties keys to set, as key=value. The key must already exist; this never creates
    # one. Use it instead of editing the live file over SFTP, so the change is planned, backed up
    # and hash-verified like everything else that reaches the server.
    #   -SetProperty 'player-idle-timeout=15'
    [string[]] $SetProperty = @(),
    # Key edits in a properties-style file under config\ on THIS server, as path:key=value. For
    # values that belong to one machine and so have no release master - the case it was written for,
    # v1.0.102, is the hardcore server's voice chat port, which it had kept from Vanilla+ when it was
    # cloned (27108) instead of its own (27322):
    #   -SetConfigProperty 'voicechat/voicechat-server.properties:port=27322'
    # Same rules as -SetProperty: the key must already exist, the live copy is backed up, and the
    # edited file goes through the plan and is hash-verified on the server like everything else.
    [string[]] $SetConfigProperty = @(),
    # Files to delete from the server outside mods\ and config\, relative to the server root - the
    # world's Voxy generation record is what this was written for:
    #   -RemoveServerFiles 'world/voxy_gen_minecraft_dimension _ minecraft_overworld.bin'
    # Each is fetched now, while the server is up, so a wrong name fails here and not mid-deploy;
    # Deploy-LiveServer fetches it again after the shutdown, because the server rewrites the record
    # as it stops, and deletes it only once that copy is in the backup. v1.0.30, v1.0.55, v1.0.56
    # and v1.0.60 all did this by hand over SFTP, which is the one step of a release that had no
    # script, no plan and no verified backup.
    [string[]] $RemoveServerFiles = @(),
    # Third-party jars to take off the server, by file name in mods\. Each must be on the server and
    # must NOT be in the release's mods folder - a jar the release still ships is a shared jar and is
    # handled by hash, and a first-party jar the release no longer ships is retired on its own. The
    # live copy goes into the backup before it is listed for removal. Written for v1.0.71, the
    # first release to withdraw a third-party server mod (FallingTree), when the only way to do it
    # was by hand over SFTP - the one step of a release that had no plan and no backup.
    #   -RemoveMods 'FallingTree-26.2-25.jar'
    [string[]] $RemoveMods = @(),
    # Values to set in the world's level.dat, as key=value on the Data compound. Written for v1.0.72,
    # when the world went from hardcore back to survival: `hardcore` lives in level.dat, not in
    # server.properties, and nothing here could change it without a hand edit over SFTP. Checked
    # now against a live copy (the key must exist); applied by Deploy-LiveServer to the copy it
    # fetches after the shutdown, because the server rewrites level.dat as it stops. Edit-LevelData.py
    # does the NBT work and refuses a key it cannot find or a type it cannot coerce.
    #   -SetLevelData 'hardcore=false'
    [string[]] $SetLevelData = @(),
    # Folders at the server root to rename after the shutdown, in order, as from=to. Written 2026-09-26
    # for the world switch of v1.0.6 (owner: "remove world and rename world2 (the actual world) to
    # world"): a rename is instant and reversible where a delete is neither, so the folder being
    # retired is moved aside, never deleted. Each source must exist and each destination must not,
    # checked against a listing of the live root now; Deploy-LiveServer applies them with
    # Sync-ServerMirror -Move once the server is confirmed down, before server.properties travels, so a
    # `level-name=` set in the same plan can only ever point at a folder that is already in place.
    #   -MoveServerFolder 'world=world.fresh-2026-09-26-retired','world2=world'
    [string[]] $MoveServerFolder = @(),
    # The local mirror to stage into. Defaults to the one Sync-ServerMirror keeps, which is the
    # server's own state as of the last pull - so the plan is computed against what is really
    # installed, not against a guess. Point it elsewhere to rehearse: a plan staged anywhere but the
    # real mirror is marked rehearsal and Deploy-LiveServer will not accept it.
    [string] $DriveRoot,
    # Skip the pull. Only when the mirror was refreshed moments ago and nothing has touched the
    # server since, because everything downstream trusts the mirror to be the server.
    [switch] $SkipPull,
    [string] $Session = $env:NBIDAL18_WINSCP_SESSION
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
if (-not (Test-Path -LiteralPath $release)) { throw "No release folder at $release" }

$mirrorDefault = Join-Path (Split-Path -Parent $repo) '_server-payload-cache'
if (-not $DriveRoot) { $DriveRoot = $mirrorDefault }
# Absolute from here on. Every path under the mirror is built from this, and a relative root - the
# hardcore deploy is typed as `..\_server-payload-cache` - once made a Substring on
# absolute file paths cut the wrong number of characters (v1.0.89, caught by a dry run).
#
# Resolved against $PWD by hand, because [IO.Path]::GetFullPath uses .NET's own current directory
# and PowerShell does NOT update that on Set-Location. Typing the documented relative root from the
# repo therefore resolved it against whatever directory the process started in, and the mirror check
# below then quietly downgraded a real deploy to a REHEARSAL (2026-09-21, the v1.0.106 hardcore
# staging - the rehearsal marker is what caught it, which is the argument for having it).
if (-not [IO.Path]::IsPathRooted($DriveRoot)) { $DriveRoot = Join-Path $PWD.ProviderPath $DriveRoot }
$DriveRoot = [IO.Path]::GetFullPath($DriveRoot).TrimEnd([char]92)
# Two live servers since 2026-09-10: the Vanilla+ mirror and, beside it, the hardcore one. A plan
# staged into either is deployable; any other tree is a rehearsal with no server behind it. The
# two get the same files: the owner's rule since 2026-09-11 evening is that nothing but the world
# and its hardcore flag differs between them (game rules are set per world, identically, by hand).
$mirrors = @($mirrorDefault, ($mirrorDefault + '-hardcore')) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd([char]92) }
$isMirror = $mirrors -contains [IO.Path]::GetFullPath($DriveRoot).TrimEnd([char]92)
$syncScript = Join-Path $PSScriptRoot 'Sync-ServerMirror.ps1'

Write-Host ("release   v{0}" -f $version)
Write-Host ("staging   {0}{1}" -f $DriveRoot, $(if ($isMirror) { '' } else { '   (REHEARSAL - not deployable)' }))

# ---------------------------------------------------------------- what this release expects
$policySource = Join-Path $release '4. server\nbidal18-integrity.properties'
if (-not (Test-Path -LiteralPath $policySource)) { throw "No generated policy at $policySource" }
$digest = (Select-String -LiteralPath $policySource -Pattern '^expected-manifest-sha256=(.+)$').Matches[0].Groups[1].Value
$localManifest = (Get-FileHash -LiteralPath (Join-Path $repo 'site\sync-manifest.json') -Algorithm SHA256).Hash.ToLower()
if ($digest -ne $localManifest) {
    throw "The policy expects $($digest.Substring(0,16))... but site\sync-manifest.json hashes to $($localManifest.Substring(0,16))... - rebuild before staging"
}

# @() because a single match comes back as a FileInfo, not an array, and .Count then throws
# under StrictMode - which is how this line was first written and how the dry run caught it.
$helpers = @(Get-ChildItem -LiteralPath (Join-Path $release '3. modpack\client\mods') -Filter 'nbidal18-integrity-*.jar')
if ($helpers.Count -ne 1) { throw "Expected exactly one integrity helper in the release, found $($helpers.Count)" }
$helperSource = $helpers[0]
if ($helperSource.Name -notlike "*-$version+*") { throw "The helper is $($helperSource.Name) but this release is $version" }
Write-Host ("digest    {0}" -f $digest.Substring(0, 16))
Write-Host ("helper    {0}" -f $helperSource.Name)

# ---------------------------------------------------------------- the mirror must be the server
# Everything below reads the mirror and calls it the live server, so it has to have been the live
# server recently. A stale mirror would compare this release against jars the server replaced weeks
# ago and report a clean deploy for files it never looked at. The pull empties mods\ and config\
# first, because WinSCP's synchronize skips a locally-newer file - which is how a rehearsal's own
# output was once read back as the server's state.
if ($isMirror -and -not $SkipPull) {
    Write-Host 'pull      refreshing the mirror from the live server'
    # Safe while the server is running: it reads, and writes nothing remote.
    # Sync-ServerMirror throws if WinSCP exits non-zero, and $ErrorActionPreference stops here.
    & $syncScript -Pull -Session $Session -MirrorRoot $DriveRoot | Out-Null
}
elseif ($isMirror) {
    Write-Host 'pull      SKIPPED by -SkipPull - the mirror is trusted to still be the server'
}

$configDir = Join-Path $DriveRoot 'config'
$modsDir = Join-Path $DriveRoot 'mods'
$propsPath = Join-Path $DriveRoot 'server.properties'
$policyLive = Join-Path $configDir 'nbidal18-integrity.properties'
$existingHelpers = @(Get-ChildItem -LiteralPath $modsDir -Filter 'nbidal18-integrity-*.jar')

# Shared jars: present on the server AND in the client pack. The helper is excluded because it is
# version-stamped and handled on its own above - matching it by name here would compare v1.0.10
# against v1.0.11 and call every release stale.
$releaseMods = Join-Path $release '3. modpack\client\mods'
# Server-only first-party jars live here and are never published to players. Added for v1.0.73's
# Mouse Wheelie server half: a jar the client pack must not carry, but the server must, and that
# the superseded-jar rule below must not sweep away as 'not in the release'.
$releaseServerMods = Join-Path $release '4. server\mods'
function Resolve-ReleaseJar([string] $name) {
    foreach ($dir in @($releaseMods, $releaseServerMods)) {
        $p = Join-Path $dir $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# Any first-party jar the server holds that this release does not ship is superseded and has to go.
# Two jars declaring one mod id is not a duplicate the loader tolerates: it picks one, and which one
# is not something to leave to chance.
#
# Read here, before the staging below deletes the old helper out of the mirror - the list has to be
# what the *server* holds, not what is left after staging. This used to cover only the integrity
# helper, because that was the only first-party jar ever deployed; nbidal18-voxyworldgen going 1.0.0
# to 1.1.0 renamed a server-side jar for the first time and would have left both installed.
#
# Scoped to nbidal18-* on purpose. A server jar that is not ours - spark, the whitelist mod - is
# server-only by definition and must never be swept up by a rule about what the client pack ships.
$releaseJarNames = @{}
foreach ($dir in @($releaseMods, $releaseServerMods)) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($jar in @(Get-ChildItem -LiteralPath $dir -Filter *.jar -File)) { $releaseJarNames[$jar.Name] = $true }
}
$superseded = @(Get-ChildItem -LiteralPath $modsDir -Filter 'nbidal18-*.jar' -File |
        Where-Object { -not $releaseJarNames.ContainsKey($_.Name) })
$shared = @()
$serverOnly = 0
foreach ($live in @(Get-ChildItem -LiteralPath $modsDir -Filter *.jar -File)) {
    if ($live.Name -like 'nbidal18-integrity-*.jar') { continue }
    $mirror = Resolve-ReleaseJar $live.Name
    # A superseded first-party jar is also absent from the release, but it is being retired rather
    # than left alone, so counting it as "server-only, untouched" would report the opposite of what
    # is about to happen to it.
    if ($null -eq $mirror) {
        if (-not ($superseded | Where-Object { $_.Name -eq $live.Name })) { $serverOnly++ }
        continue
    }
    $shared += [pscustomobject]@{
        Name = $live.Name
        Live = $live.FullName
        Source = $mirror
        # Read both through the same call the deploy uses, so a stale mount shows up here and not
        # after the write.
        Stale = (Get-FileHash -LiteralPath $live.FullName -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $mirror -Algorithm SHA256).Hash
    }
}
$staleShared = @($shared | Where-Object { $_.Stale })
$clientOnly = @(Get-ChildItem -LiteralPath $releaseMods -Filter *.jar -File).Count - $shared.Count - 1

# Refuse a name that is already there as loudly as one that does not exist. A jar the server has is
# a shared jar and is compared by hash above; listing it here too would mean two rules deciding the
# same file, and the answer to "was it deployed?" would depend on which ran last.
$added = @()
foreach ($name in $AddMods) {
    $source = Resolve-ReleaseJar $name
    if ($null -eq $source) {
        throw "-AddMods named $name, which is in neither the release's client mods nor its 4. server\mods"
    }
    $live = Join-Path $modsDir $name
    if (Test-Path -LiteralPath $live -PathType Leaf) {
        throw "-AddMods named $name, which the server already has - it is a shared jar and is handled by hash"
    }
    $added += [pscustomobject]@{ Name = $name; Live = $live; Source = $source }
}

$removedMods = @()
foreach ($name in $RemoveMods) {
    if ($name -match '[\\/]' -or $name -notlike '*.jar') { throw "-RemoveMods takes a jar file name in mods\, not a path: $name" }
    if ($name -like 'nbidal18-*') { throw "-RemoveMods named $name, a first-party jar - those are retired automatically once the release stops shipping them" }
    if ($null -ne (Resolve-ReleaseJar $name)) {
        throw "-RemoveMods named $name, which the release still ships - remove it from the release first, or it is a shared jar"
    }
    $live = Join-Path $modsDir $name
    if (-not (Test-Path -LiteralPath $live -PathType Leaf)) { throw "-RemoveMods named $name, which the server does not have" }
    $removedMods += [pscustomobject]@{ Name = $name; Live = $live }
}

# Unlike -AddMods these may already exist - both files this was written for did - so an existing
# copy is overwritten rather than refused. One that already matches is dropped from the plan so the
# report says what will actually change.
$releaseConfig = Join-Path $release '3. modpack\client\config'
# Server-only configs live here, the way 4. server\mods holds server-only jars: a file the client
# never sees - the mod writes its own on each side - but whose server copy the pack decides. Added for
# v1.0.74's the-block-keeps-ticking.json (leaf-decay catch-up off; it forced synchronous chunk loads
# on the main thread at every disconnect). The client copy wins when both exist, so a published
# config is never shadowed by a server-only one of the same name.
$releaseServerConfig = Join-Path $release '4. server\config'
# Better Compatibility Checker's file carries the pack version and is compared client against
# server at every join, so the server's copy has to move with every release the way the policy
# and the helper do. Routine, not optional: it is added to whatever -Config named. (BCC 26.2 reads
# config/bcc-common.json only; the bcc-common.toml still on the server is dead and harmless.)
$Config = @('bcc-common.json') + @($Config | Where-Object { $_ -ne 'bcc-common.json' })
$configFiles = @()
foreach ($name in $Config) {
    # 'server:' prefix: take the 4. server\config copy even though a published client copy of the
    # same name exists. For a file that is player-class on the client - never re-delivered, never
    # enforced - but whose server copy is what the game actually reads (v1.0.75: Vanilla Refresh's
    # soul, off on the server, seeded off on clients).
    # Not $serverOnly: that is the count of server-only jars the summary prints, and reusing the
    # name here made the summary say 'False server-only jars' whenever a config was staged.
    $fromServerCopy = $name.StartsWith('server:')
    if ($fromServerCopy) { $name = $name.Substring(7) }
    $source = Join-Path $releaseConfig $name
    if ($fromServerCopy -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $source = Join-Path $releaseServerConfig $name
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "-Config named $name, which is in neither the release's published config\ nor its 4. server\config"
    }
    $live = Join-Path $configDir $name
    if ((Test-Path -LiteralPath $live -PathType Leaf) -and
        (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) {
        continue
    }
    $configFiles += [pscustomobject]@{ Name = $name; Live = $live; Source = $source }
}

# -SetConfigProperty: this machine's own copy, edited key by key. The edited text is written to a
# scratch file that becomes the "source" of an ordinary config entry, so staging, the plan, the push
# and the hash check are the ones every other config already goes through. `[^\r\n]*` rather than
# `.*`, because `.` matches the carriage return and would strip it from a CRLF file's edited line.
$configEditBackups = @()
if ($SetConfigProperty.Count) {
    $editScratch = Join-Path ([IO.Path]::GetTempPath()) ('nbidal18-config-edit-' + [Guid]::NewGuid())
    $byFile = [ordered]@{}
    foreach ($spec in $SetConfigProperty) {
        if ($spec -notmatch '^([^:=]+):([A-Za-z][A-Za-z0-9_.\-]*)=(.*)$') {
            throw "Not a config edit: '$spec'. Expected path/under/config:key=value."
        }
        $rel = $Matches[1].Replace([char]47, [IO.Path]::DirectorySeparatorChar)
        if ($rel -match '\.\.') { throw "-SetConfigProperty path may not contain '..': $rel" }
        if (-not $byFile.Contains($rel)) { $byFile[$rel] = [ordered]@{} }
        $byFile[$rel][$Matches[2]] = $Matches[3]
    }
    foreach ($rel in $byFile.Keys) {
        if (@($configFiles | Where-Object { $_.Name -eq $rel }).Count) {
            throw "$rel is named by both -Config and -SetConfigProperty; pick one"
        }
        $live = Join-Path $configDir $rel
        if (-not (Test-Path -LiteralPath $live -PathType Leaf)) {
            throw "-SetConfigProperty names config\$rel, which is not on this server (pulled into $configDir)"
        }
        $before = [IO.File]::ReadAllText($live)
        $after = $before
        foreach ($key in $byFile[$rel].Keys) {
            $pattern = '(?m)^' + [regex]::Escape($key) + '=[^\r\n]*'
            $now = [regex]::Match($after, $pattern)
            if (-not $now.Success) {
                throw "config\$rel has no key '$key'. Refusing to create one - check the spelling against the live file."
            }
            $line = $key + '=' + $byFile[$rel][$key]
            Write-Host ("  setting  config\{0}: {1}  ->  {2}" -f $rel, $now.Value, $line)
            $after = [regex]::Replace($after, $pattern, { $line })
        }
        if ($after -ceq $before) {
            Write-Host ("  setting  config\{0} already says that - nothing to send" -f $rel)
            continue
        }
        $source = Join-Path $editScratch $rel
        [IO.Directory]::CreateDirectory((Split-Path -Parent $source)) | Out-Null
        [IO.File]::WriteAllText($source, $after, (New-Object Text.UTF8Encoding($false)))
        $configFiles += [pscustomobject]@{ Name = $rel; Live = $live; Source = $source }
        $configEditBackups += $live
    }
}

$levelDataEdits = [ordered]@{}
if ($SetLevelData.Count) {
    $editor = Join-Path $PSScriptRoot 'Edit-LevelData.py'
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('nbidal18-leveldata-' + [Guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    try {
        $liveCopy = Join-Path $probe 'level.dat'
        # The folder to probe is the one the server will load after this deploy: a `level-name=` in
        # -SetProperty wins over the live file's value. Deploy-LiveServer resolves it the same way.
        $probeLevel = 'world'
        if ((Get-Content -LiteralPath $propsPath -Raw) -match '(?m)^level-name=(.*)$') { $probeLevel = $Matches[1].Trim() }
        foreach ($pair in $SetProperty) { if ($pair -match '^level-name=(.+)$') { $probeLevel = $Matches[1].Trim() } }
        if ($isMirror) {
            Write-Host ("  leveldat probing {0}/level.dat" -f $probeLevel)
            & $syncScript -Get "$probeLevel/level.dat" -To $liveCopy -Session $Session -MirrorRoot $DriveRoot | Out-Null
            if (-not (Test-Path -LiteralPath $liveCopy -PathType Leaf)) { throw "Could not fetch $probeLevel/level.dat to check -SetLevelData against" }
            $probeOut = Join-Path $probe 'level.edited.dat'
            $report = & python $editor $liveCopy $probeOut @SetLevelData 2>&1
            if ($LASTEXITCODE -ne 0) { throw "-SetLevelData was refused by Edit-LevelData.py: $report" }
            foreach ($line in @($report)) { if ($line -match '->') { Write-Host ('  leveldat ' + $line) } }
        }
        else { Write-Host '  leveldat (rehearsal - not checked against the server)' }
    }
    finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($pair in $SetLevelData) {
        $key, $value = $pair -split '=', 2
        if (-not $key -or $null -eq $value) { throw "-SetLevelData takes key=value, not '$pair'" }
        $levelDataEdits[$key] = $value
    }
}

$propsText = [IO.File]::ReadAllText($propsPath)
$motdNow = ([regex]::Match($propsText, '(?m)^motd=.*$')).Value
# The version is what this rewrites; a label a server carries after it ("v1.0.87 Hardcore - ...",
# the second machine since 2026-09-10) is kept, so one script serves both servers.
$wantMotd = "motd=v$version - @nbidal18 on Discord"
if ($motdNow -match '^motd=v[0-9.]+( .+?)? - @nbidal18 on Discord$' -and $Matches[1]) {
    $wantMotd = "motd=v$version$($Matches[1]) - @nbidal18 on Discord"
}
# A line that wants a different label says so in MOTD-SUFFIX.txt beside the scripts (data file, like
# PACK-NAME.txt), and that wins over whatever the live motd carried. Added 2026-09-26 when the
# hardcore line became Vanilla++: keeping the label from the live file would have kept "Hardcore".
$suffixFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'MOTD-SUFFIX.txt'
if (Test-Path -LiteralPath $suffixFile -PathType Leaf) {
    $suffix = (Get-Content -LiteralPath $suffixFile -Raw).Trim()
    if ($suffix) { $wantMotd = "motd=v$version $suffix - @nbidal18 on Discord" }
}

# Named server.properties edits, beyond the motd this has always rewritten.
#
# Until v1.0.49 the motd was the ONLY key this could touch, so changing anything else - the idle
# timeout, a view distance - meant editing the live file by hand over SFTP: no backup taken by the
# tooling, no hash check, no record of what it used to say. Every other deployed byte in this pack
# goes through a plan that is reviewed, backed up and verified, and there was no reason for
# server.properties to be the exception.
#
# A key must already exist. Creating one silently is how a typo becomes a setting that looks applied
# and does nothing - `player-idle-timout=15` would sit in the file forever being ignored.
$propertyEdits = [ordered]@{}
foreach ($pair in $SetProperty) {
    if ($pair -notmatch '^([a-z][a-z0-9.\-]*)=(.*)$') {
        throw "Not a server.properties assignment: '$pair'. Expected key=value."
    }
    $key = $Matches[1]
    $value = $Matches[2]
    if ($key -eq 'motd') { throw 'The motd is set from the pack version and cannot be overridden here.' }
    if ($propsText -notmatch ("(?m)^" + [regex]::Escape($key) + "=")) {
        throw "server.properties has no key '$key'. Refusing to create one - check the spelling against the live file."
    }
    $propertyEdits[$key] = $value
}

# Folder renames: validated against the live root listing, applied at deploy time.
$moveFolders = @()
if ($MoveServerFolder.Count) {
    $present = @()
    if ($isMirror) {
        $present = @(& $syncScript -List '/' -Session $Session -MirrorRoot $DriveRoot 2>&1 |
            Where-Object { $_ -match '^d' } | ForEach-Object { ([string] $_ -split '\s+', 10)[-1] })
    }
    $will = New-Object System.Collections.Generic.List[string]
    foreach ($name in $present) { $will.Add([string] $name) }
    foreach ($pair in $MoveServerFolder) {
        if ($pair -notmatch '^([A-Za-z0-9._-]+)=([A-Za-z0-9._-]+)$') { throw "-MoveServerFolder takes from=to with plain folder names, not '$pair'" }
        $from, $to = $Matches[1], $Matches[2]
        if ($isMirror) {
            if (-not $will.Contains($from)) { throw "-MoveServerFolder: '$from' is not a folder at the server root (or was already moved by an earlier pair)" }
            if ($will.Contains($to)) { throw "-MoveServerFolder: '$to' already exists at the server root; refusing to move over it" }
            $will.Remove($from) | Out-Null; $will.Add($to)
        }
        $moveFolders += [pscustomobject]@{ from = $from; to = $to }
    }
}

Write-Host ''
Write-Host 'would change:'
Write-Host ("  policy   {0}" -f $policyLive)
Write-Host ("  helper   {0}  ->  {1}" -f (($existingHelpers | ForEach-Object { $_.Name }) -join ', '), $helperSource.Name)
Write-Host ("  motd     {0}  ->  {1}" -f $motdNow, $wantMotd)
foreach ($key in $propertyEdits.Keys) {
    $now = ([regex]::Match($propsText, "(?m)^" + [regex]::Escape($key) + "=.*$")).Value
    Write-Host ("  property {0}  ->  {1}={2}" -f $now, $key, $propertyEdits[$key])
}
if ($staleShared.Count) {
    foreach ($jar in $staleShared) { Write-Host ("  jar      {0}" -f $jar.Name) }
}
else {
    Write-Host ("  jars     none - all {0} shared jars already match" -f $shared.Count)
}
foreach ($jar in $added) { Write-Host ("  new jar  {0}" -f $jar.Name) }
foreach ($cfg in $configFiles) { Write-Host ("  config   {0}" -f $cfg.Name) }
foreach ($old in $superseded) { Write-Host ("  retire   {0}" -f $old.Name) }
foreach ($jar in $removedMods) { Write-Host ("  remove   {0}  (backed up now, deleted at deploy)" -f $jar.Name) }
foreach ($rel in $RemoveServerFiles) { Write-Host ("  delete   {0}  (after a fresh backup at deploy time)" -f $rel) }
foreach ($key in $levelDataEdits.Keys) { Write-Host ("  leveldat {0}={1}  (applied to the post-shutdown copy at deploy time)" -f $key, $levelDataEdits[$key]) }
foreach ($mv in $moveFolders) { Write-Host ("  move     {0}  ->  {1}  (server root, after the shutdown, before anything else is written)" -f $mv.from, $mv.to) }
Write-Host ("           {0} server-only jars untouched, {1} client-only jars not considered" -f $serverOnly, $clientOnly)

# ---------------------------------------------------------------- back up, and prove the backup
$stamp = (Get-Date -Format 'yyyy-MM-dd') + "-v$version"
$backup = Join-Path (Join-Path $DriveRoot '.nbidal18-deploy-backups') $stamp
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$toBackUp = @($policyLive, $propsPath) + ($existingHelpers | ForEach-Object { $_.FullName }) +
    ($staleShared | ForEach-Object { $_.Live }) + ($removedMods | ForEach-Object { $_.Live }) +
    @($configEditBackups)
foreach ($p in $toBackUp) {
    $dest = Join-Path $backup (Split-Path $p -Leaf)
    [IO.File]::WriteAllBytes($dest, [IO.File]::ReadAllBytes($p))
    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash) {
        throw "The backup of $p does not match the live file - the mount served stale content, do not proceed"
    }
}
Write-Host ("backup    {0} files -> {1}" -f $toBackUp.Count, $backup)

# A file to delete has to exist to be deleted, and proving that with the server still up costs a
# small fetch here rather than a failed deploy with the server already down. This copy is labelled
# pre-shutdown because it is not the rollback point: the server rewrites its generation record as
# it stops, and Deploy-LiveServer takes the real backup after that.
foreach ($rel in $RemoveServerFiles) {
    if ($rel -match '^(mods|config)[\\/]' -or $rel -match '\.\.') {
        throw "-RemoveServerFiles is for files outside mods\ and config\, with no '..' in the path: $rel"
    }
    if (-not $isMirror) {
        Write-Host ("delete    {0}  (rehearsal - not fetched)" -f $rel)
        continue
    }
    $copy = Join-Path $backup ('pre-shutdown-' + (Split-Path $rel -Leaf))
    & $syncScript -Get ($rel -replace '\\', '/') -To $copy -Session $Session -MirrorRoot $DriveRoot | Out-Null
    if (-not (Test-Path -LiteralPath $copy -PathType Leaf)) {
        throw "Could not fetch $rel from the server - it is not there to delete, or the name is wrong"
    }
    Write-Host ("delete    {0}  ({1} bytes on the server now; pre-shutdown copy in the backup)" -f $rel, (Get-Item -LiteralPath $copy).Length)
}

# ---------------------------------------------------------------- stage
[IO.File]::WriteAllBytes($policyLive, [IO.File]::ReadAllBytes($policySource))
[IO.File]::WriteAllBytes((Join-Path $modsDir $helperSource.Name), [IO.File]::ReadAllBytes($helperSource.FullName))
foreach ($old in $existingHelpers) {
    if ($old.Name -ne $helperSource.Name) { [IO.File]::Delete($old.FullName) }
}
$propsWanted = [regex]::Replace($propsText, '(?m)^motd=.*$', { $wantMotd })
foreach ($key in $propertyEdits.Keys) {
    $line = "$key=" + $propertyEdits[$key]
    $propsWanted = [regex]::Replace($propsWanted, "(?m)^" + [regex]::Escape($key) + "=.*$", { $line })
}
[IO.File]::WriteAllText($propsPath, $propsWanted)
foreach ($jar in @($staleShared) + @($added) + @($configFiles)) {
    # A config inside a folder the mirror does not have yet (v1.0.86: config\controlify\server.json,
    # a folder the mod only creates on its first boot) needs the folder made here; on the server
    # Sync-ServerMirror makes it at push time.
    [IO.Directory]::CreateDirectory((Split-Path -Parent $jar.Live)) | Out-Null
    [IO.File]::WriteAllBytes($jar.Live, [IO.File]::ReadAllBytes($jar.Source))
}

# ---------------------------------------------------------------- verify what was staged
$failures = New-Object Collections.Generic.List[string]
$verify = @(
    @{ s = $policySource; d = $policyLive },
    @{ s = $helperSource.FullName; d = (Join-Path $modsDir $helperSource.Name) })
foreach ($jar in @($staleShared) + @($added) + @($configFiles)) { $verify += @{ s = $jar.Source; d = $jar.Live } }
foreach ($pair in $verify) {
    $a = (Get-FileHash -LiteralPath $pair.s -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $pair.d -Algorithm SHA256).Hash
    $sa = (Get-Item -LiteralPath $pair.s).Length
    $sb = (Get-Item -LiteralPath $pair.d).Length
    if ($a -ne $b -or $sa -ne $sb) { $failures.Add((Split-Path $pair.d -Leaf)) }
    Write-Host ("{0}  {1,-46} {2,8} B" -f $(if ($a -eq $b -and $sa -eq $sb) { 'MATCH   ' } else { 'MISMATCH' }), (Split-Path $pair.d -Leaf), $sb)
}

$stale = @(Get-ChildItem -LiteralPath $modsDir -Filter 'nbidal18-integrity-*.jar' | Where-Object { $_.Name -ne $helperSource.Name })
if ($stale.Count) { $failures.Add('an older helper is still installed: ' + (($stale | ForEach-Object { $_.Name }) -join ', ')) }

# server.properties may lose nothing but the motd and the server's own date stamp.
$before = [IO.File]::ReadAllText((Join-Path $backup 'server.properties')) -split "`r?`n"
$after = [IO.File]::ReadAllText($propsPath) -split "`r?`n"
$keysBefore = @($before | Where-Object { $_ -match '^[a-z][a-z0-9.\-]*=' } | ForEach-Object { ($_ -split '=', 2)[0] })
$keysAfter = @($after | Where-Object { $_ -match '^[a-z][a-z0-9.\-]*=' } | ForEach-Object { ($_ -split '=', 2)[0] })
if (Compare-Object $keysBefore $keysAfter) { $failures.Add('server.properties gained or lost a key') }
Write-Host ("MATCH     server.properties {0} keys, motd -> v{1}" -f $keysAfter.Count, $version)

# Re-read every shared jar rather than trusting the copies above. This is the check that would have
# caught both forks, and it is cheap next to the outage it prevents.
$stillStale = @()
foreach ($jar in $shared) {
    if ((Get-FileHash -LiteralPath $jar.Live -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $jar.Source -Algorithm SHA256).Hash) {
        $stillStale += $jar.Name
    }
}
if ($stillStale.Count) { $failures.Add('shared jars still differ: ' + ($stillStale -join ', ')) }
Write-Host ("MATCH     {0} shared jars byte-identical to the release" -f $shared.Count)

if ($failures.Count) { throw ('Staging did not verify: ' + ($failures -join '; ')) }

# ---------------------------------------------------------------- hand over
# The plan is the handover, and it is deliberately explicit: Deploy-LiveServer sends this list and
# nothing else, and re-hashes every entry before it sends it. A plan is not a suggestion of what
# might need deploying - it is the whole permitted set.
$sendFiles = @('config\nbidal18-integrity.properties', ('mods\' + $helperSource.Name), 'server.properties')
foreach ($jar in @($staleShared) + @($added)) { $sendFiles += ('mods\' + $jar.Name) }
foreach ($cfg in $configFiles) { $sendFiles += ('config\' + $cfg.Name) }
$sendRemove = @($superseded | ForEach-Object { 'mods\' + $_.Name }) + @($removedMods | ForEach-Object { 'mods\' + $_.Name })

$send = @()
foreach ($rel in $sendFiles) {
    $send += [pscustomobject]@{
        rel = $rel
        sha256 = (Get-FileHash -LiteralPath (Join-Path $DriveRoot $rel) -Algorithm SHA256).Hash.ToLower()
    }
}

$plan = [pscustomobject]@{
    version      = $version
    digest       = $digest
    mirrorRoot   = [IO.Path]::GetFullPath($DriveRoot).TrimEnd([char]92)
    rehearsal    = (-not $isMirror)
    stagedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    motd         = $wantMotd
    # Carried so Deploy-LiveServer can re-apply them to the copy it re-reads after the shutdown.
    # The server rewrites server.properties as it stops, so anything staged against the running
    # copy is already behind by the time the push happens - the motd has always been re-applied
    # there for exactly this reason, and these have to travel the same way or they vanish.
    properties   = $propertyEdits
    backup       = $backup
    send         = $send
    remove       = $sendRemove
    # Deleted only after Deploy-LiveServer has fetched a post-shutdown copy into the backup.
    removeAfterBackup = @($RemoveServerFiles)
    # Applied by Deploy-LiveServer to the level.dat it fetches after the shutdown; see -SetLevelData.
    levelData    = $levelDataEdits
    # Folder renames at the server root, applied by Deploy-LiveServer after the shutdown; see -MoveServerFolder.
    moveFolders  = @($moveFolders)
    sharedJars   = $shared.Count
    staleShared  = $staleShared.Count
    addedJars    = $added.Count
}
$planPath = Join-Path $DriveRoot '.nbidal18-deploy-plan.json'
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

Write-Host ''
if ($isMirror) {
    Write-Host ("OK        {0} file(s) staged and verified, {1} jar(s) to remove, {2} file(s) to delete after backup. Plan written to {3}" -f $send.Count, $sendRemove.Count, @($RemoveServerFiles).Count, (Split-Path $planPath -Leaf))
    Write-Host '          Nothing has reached the server. Push and wait for Pages, then:'
    Write-Host '          scripts\Deploy-LiveServer.ps1 -Apply -WaitForShutdown 900'
}
else {
    Write-Host ("OK        rehearsal complete: {0} file(s) staged and verified in {1}. The live server was not touched, and this plan is not deployable." -f $send.Count, $DriveRoot)
}
