<#
    Sends a staged deployment to the live server, and proves it landed. It decides nothing.

      scripts\Deploy-LiveServer.ps1                              show the plan, change nothing
      scripts\Deploy-LiveServer.ps1 -Apply -WaitForShutdown 900  send it
      scripts\Deploy-LiveServer.ps1 -Apply                       send it, server already stopped

    **Run `Test-ServerDeployment.ps1` first.** That is where the pull, the plan, the staging, the
    backups and the hash checks live. This script reads the plan it wrote, refuses to send anything
    that is not in it, and does nothing else. The two were one script until v1.0.38, and the cost of
    that was structural: the only way to run the slow, read-only half was to run the deploy, so it
    ran with the server already stopped and the outage carried a 169 MB pull nobody was waiting on.
    Splitting them is what makes it possible to do all the work while players are still on.

    So the shape of a release is three separate steps, in this order:

      1. make the change, build it, and run the client and server tests
      2. scripts\Test-ServerDeployment.ps1   - pull, plan, stage, verify, write the plan
      3. push, wait for Pages, verify the channel, then this

    **Prefer -WaitForShutdown**, and start this while the server is still up. It checks the plan and
    the channel, then waits for you to stop the server from the provider panel and pushes within
    seconds of the port closing.

    **It reaches the server over SFTP, not a drive letter.** It used to write to `Y:`, a CloudMounter
    SFTP mount, and when that trial expired the default pointed at a drive that no longer existed -
    so every run since died on `Cannot find drive` and the deploy was finished by hand with
    Sync-ServerMirror, which is the exact exposure this script exists to remove.

    Refusals, all of which have a real incident behind them:

      the plan must exist, and must be for this version, this digest and this mirror. A plan staged
      against a different release describes files that are no longer what the release ships, and a
      rehearsal plan is refused outright.

      every staged file is re-hashed against the plan immediately before it is sent. Staging and
      sending are now separate runs, possibly minutes apart, and nothing may travel that changed in
      between.

      the channel must already serve this release's digest. Deploying first means the server demands
      a manifest nobody can download yet, so every launching client is refused for the whole of the
      Pages propagation, on top of the outage.

      the server must be down before anything is written, proved by a Server List Ping and not by a
      TCP connect or a log timestamp. The ping runs immediately before the first write, never
      earlier, so an "it's off" from a minute ago is never carried forward. -WaitForShutdown makes it
      wait for the port to close rather than refuse; it never makes it skip the proof, and the second
      ping before the first remote byte is unchanged. The pack pauses when empty, so a running server
      writes nothing for hours; the host can hold the port open with the server stopped; and log
      timestamps are UTC while the clock here is not.

      `server.properties` and the integrity policy are re-read off the server after the shutdown,
      because the server rewrites both as it stops - it escapes `level-type` and restamps its date
      comment. The staged copy predates that, and sending it would silently undo the server's own
      last write. The MOTD is re-applied to the fresh copy here, which is the one edit this script
      makes and the only one it is allowed to.

      every file is read back off the server afterwards and hashed. A push that reported success and
      a file that is actually there are different claims, and only the second keeps players out of a
      lockout.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    # The mirror the plan was staged into. Must match the plan's own record of it.
    [string] $DriveRoot,
    [string] $Session = $env:NBIDAL18_WINSCP_SESSION,
    [int] $TimeoutSec = 8,
    # Seconds to wait for the server to go down, instead of refusing the moment it answers. Start
    # this with the server still up and stop it from the panel when the script says it is waiting;
    # the push then goes out within seconds of the port closing.
    [int] $WaitForShutdown = 0,
    # host:port of the server being deployed to, for the shutdown pings. SERVER.txt names the
    # Vanilla+ server and is the default; the hardcore server (2026-09-10, a second machine on a
    # different node) is deployed with -Session, -DriveRoot and this all pointing at it - see
    # server.md, "The hardcore server".
    [string] $ServerAddress
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
if (-not (Test-Path -LiteralPath $release)) { throw "No release folder at $release" }

$serverFile = Join-Path $repo 'SERVER.txt'
if (-not (Test-Path -LiteralPath $serverFile)) { throw "No SERVER.txt at $serverFile" }
$address = if ($ServerAddress) { $ServerAddress.Trim() } else { (Get-Content -LiteralPath $serverFile -Raw).Trim() }
$serverHost, $serverPort = $address -split ':', 2
$serverPort = [int] $serverPort

if (-not $DriveRoot) { $DriveRoot = Join-Path (Split-Path -Parent $repo) '_server-payload-cache' }
# Against $PWD by hand: [IO.Path]::GetFullPath uses .NET's current directory, which PowerShell does
# not update on Set-Location, so the documented relative root resolved against the wrong folder.
if (-not [IO.Path]::IsPathRooted($DriveRoot)) { $DriveRoot = Join-Path $PWD.ProviderPath $DriveRoot }
$DriveRoot = [IO.Path]::GetFullPath($DriveRoot).TrimEnd([char]92)
$syncScript = Join-Path $PSScriptRoot 'Sync-ServerMirror.ps1'

# SERVER.txt holds one address - Vanilla+'s - and it is what the liveness ping below asks whether a
# server is running. The mirror is what decides which server is actually being deployed, so any other
# server deployed against that address pings the wrong machine, and can report 'confirmed down' about
# a server that is not the one about to be written to.
#
# Found on 2026-09-12 deploying v1.0.96 to Vanilla+ Hardcore: the run printed 194.54.88.14:27107
# while correctly sending the hardcore plan over the hardcore session into the hardcore mirror. Both
# servers happened to be off, so nothing was written under a running one - but had hardcore been up
# and Vanilla+ down, this would have written into a live server, which every rule here exists to
# prevent. Rather than invent a mirror-to-address map, it refuses: a non-default mirror must be told
# its own address.
$defaultMirror = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $repo) '_server-payload-cache')).TrimEnd([char]92)
if ($DriveRoot -ne $defaultMirror -and -not $ServerAddress) {
    throw ("This mirror is not the default one, so SERVER.txt's address is not its server. " +
           "Mirror: $DriveRoot. SERVER.txt: $address. Pass -ServerAddress '<host>:<port>' for the " +
           "server this mirror belongs to - otherwise the liveness check pings a different machine.")
}

Write-Host ("release   v{0}" -f $version)
Write-Host ("server    {0}" -f $address)

# ---------------------------------------------------------------- the plan, and whether it is ours
$planPath = Join-Path $DriveRoot '.nbidal18-deploy-plan.json'
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "No deployment plan at $planPath - run scripts\Test-ServerDeployment.ps1 first. This script only sends what that staged."
}
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
if ($plan.rehearsal) { throw 'That plan was staged as a rehearsal, into a tree with no server behind it. It is not deployable.' }
if ($plan.version -ne $version) { throw "The plan is for v$($plan.version) but PACK-VERSION.txt says $version - re-stage." }
if ($plan.mirrorRoot -ne $DriveRoot) { throw "The plan was staged into $($plan.mirrorRoot) but this is $DriveRoot - re-stage." }

$policySource = Join-Path $release '4. server\nbidal18-integrity.properties'
if (-not (Test-Path -LiteralPath $policySource)) { throw "No generated policy at $policySource" }
$digest = (Select-String -LiteralPath $policySource -Pattern '^expected-manifest-sha256=(.+)$').Matches[0].Groups[1].Value
if ($plan.digest -ne $digest) {
    throw "The plan expects $($plan.digest.Substring(0,16))... but the release's policy now says $($digest.Substring(0,16))... - the release was rebuilt after staging, so re-stage."
}
Write-Host ("plan      {0}, staged {1}" -f (Split-Path $planPath -Leaf), $plan.stagedUtc)
Write-Host ("digest    {0}" -f $digest.Substring(0, 16))

# ---------------------------------------------------------------- the channel must be ahead of us
$packUrl = (Get-Content -LiteralPath (Join-Path $repo 'UPDATE-URL.txt') -Raw).Trim()
$manifestUrl = ($packUrl -replace '[^/]+$', '') + 'sync-manifest.json'
$tmp = Join-Path $env:TEMP ("nbidal18-live-manifest-" + [Guid]::NewGuid() + '.json')
try {
    Invoke-WebRequest -Uri ($manifestUrl + '?cb=' + [Guid]::NewGuid()) -OutFile $tmp -UseBasicParsing -TimeoutSec 30
    $served = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
if ($served -ne $digest) {
    # Only a real deploy is refused. A dry run sends nothing, and being unable to read the plan until
    # after the push made the push the first time anyone saw it.
    $msg = ("The channel serves $($served.Substring(0,16))... but this release is $($digest.Substring(0,16))... - " +
        'push and wait for Pages first. Deploying ahead of the channel refuses every launching client.')
    if ($Apply) { throw $msg }
    Write-Host ("channel   BEHIND - {0}" -f $msg)
}
else { Write-Host 'channel   already serving this release' }

Write-Host ''
Write-Host ("will send: {0} file(s), {1} shared jar(s) refreshed, {2} new jar(s)" -f `
        @($plan.send).Count, $plan.staleShared, $plan.addedJars)
foreach ($f in $plan.send) { Write-Host ("  send     {0}" -f $f.rel) }
foreach ($r in @($plan.remove)) { Write-Host ("  remove   {0}" -f $r) }
# Absent from a plan staged before v1.0.61, and under StrictMode a missing property throws rather
# than reading as empty.
$afterBackup = @()
if ($plan.PSObject.Properties.Name -contains 'removeAfterBackup' -and $null -ne $plan.removeAfterBackup) {
    $afterBackup = @($plan.removeAfterBackup)
}
foreach ($r in $afterBackup) { Write-Host ("  delete   {0}  (after a fresh backup)" -f $r) }
$levelDataEdits = @()
if ($plan.PSObject.Properties.Name -contains 'levelData' -and $null -ne $plan.levelData) {
    foreach ($prop in $plan.levelData.PSObject.Properties) { $levelDataEdits += ($prop.Name + '=' + $prop.Value) }
}
foreach ($e in $levelDataEdits) { Write-Host ("  leveldat {0}  (edited on the post-shutdown copy, after a backup)" -f $e) }
Write-Host ("  motd     {0}" -f $plan.motd)
Write-Host ("  backup   {0}" -f $plan.backup)

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Dry run. Re-run with -Apply to send it.'
    return
}

# ---------------------------------------------------------------- the server must be down
function Get-VarInt([int] $value) {
    $bytes = New-Object Collections.Generic.List[byte]
    while ($true) {
        $b = $value -band 0x7F
        $value = [int] (([uint32] $value) -shr 7)
        if ($value -ne 0) { $bytes.Add([byte] ($b -bor 0x80)) } else { $bytes.Add([byte] $b); break }
    }
    return , $bytes.ToArray()
}

function Test-ServerUp {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($serverHost, $serverPort)
        if (-not $task.Wait($TimeoutSec * 1000) -or -not $client.Connected) { return $false }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSec * 1000

        $hostBytes = [Text.Encoding]::UTF8.GetBytes($serverHost)
        $payload = New-Object Collections.Generic.List[byte]
        $payload.AddRange((Get-VarInt 0))            # packet id: handshake
        $payload.AddRange((Get-VarInt 767))          # protocol
        $payload.AddRange((Get-VarInt $hostBytes.Length))
        $payload.AddRange($hostBytes)
        $payload.Add([byte] (($serverPort -shr 8) -band 0xFF))
        $payload.Add([byte] ($serverPort -band 0xFF))
        $payload.AddRange((Get-VarInt 1))            # next state: status
        $frame = @((Get-VarInt $payload.Count)) + $payload
        $stream.Write($frame, 0, $frame.Length)

        $request = @((Get-VarInt 1)) + (Get-VarInt 0)
        $stream.Write($request, 0, $request.Length)
        $stream.Flush()

        # A single byte back is enough: only a running Minecraft server answers a status request.
        return ($stream.ReadByte() -ge 0)
    }
    catch { return $false }
    finally { $client.Close() }
}

if ((Test-ServerUp) -and $WaitForShutdown -gt 0) {
    Write-Host ("server    up - waiting up to {0}s. Stop it from the provider panel now." -f $WaitForShutdown)
    $deadline = (Get-Date).AddSeconds($WaitForShutdown)
    while (Test-ServerUp) {
        if ((Get-Date) -gt $deadline) { throw "The server was still up after ${WaitForShutdown}s. Nothing was sent." }
        Start-Sleep -Seconds 3
    }
}
if (Test-ServerUp) {
    throw ('The server answered a status ping. Stop it from the provider panel; the helper jar, the ' +
        'shared jars and the MOTD are not hot-reloadable. Pass -WaitForShutdown to wait for the port ' +
        'to close instead of refusing.')
}
Write-Host 'server    confirmed down (no status reply)'

# ---------------------------------------------------------------- what the shutdown rewrote
# The staging ran while the server was still serving, so its copies of these two predate the
# shutdown. The server escapes level-type and restamps its date comment as it stops, and sending
# the older copy would silently undo that. Only these two: the server never rewrites a jar or a
# mod's config.
$propsPath = Join-Path $DriveRoot 'server.properties'
$policyLive = Join-Path (Join-Path $DriveRoot 'config') 'nbidal18-integrity.properties'
$fresh = Join-Path $env:TEMP ('nbidal18-deploy-fresh-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $fresh | Out-Null
try {
    $freshProps = Join-Path $fresh 'server.properties'
    $freshPolicy = Join-Path $fresh 'nbidal18-integrity.properties'
    & $syncScript -Get 'server.properties' -To $freshProps -Session $Session -MirrorRoot $DriveRoot | Out-Null
    & $syncScript -Get 'config/nbidal18-integrity.properties' -To $freshPolicy -Session $Session -MirrorRoot $DriveRoot | Out-Null

    # The backup is the rollback point, so it has to be what the server actually held at the moment
    # it went down - not what it held while it was still running.
    foreach ($pair in @(@{ f = $freshProps; n = 'server.properties' }, @{ f = $freshPolicy; n = 'nbidal18-integrity.properties' })) {
        $dest = Join-Path $plan.backup $pair.n
        [IO.File]::WriteAllBytes($dest, [IO.File]::ReadAllBytes($pair.f))
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $pair.f -Algorithm SHA256).Hash) {
            throw "The backup of $($pair.n) does not match what was read off the server - do not proceed"
        }
    }
    Write-Host ("backup    server.properties and the policy re-read after the shutdown -> {0}" -f $plan.backup)

    $freshText = [IO.File]::ReadAllText($freshProps)
    $stagedText = [IO.File]::ReadAllText($propsPath)
    $wantText = [regex]::Replace($freshText, '(?m)^motd=.*$', { $plan.motd })
    # Same treatment for any named key edits. Applied to the freshly-read copy, not the staged one,
    # so the server's own shutdown rewrite is preserved and only the keys we named are changed.
    # Enumerated through ForEach-Object rather than reading .Name off the collection directly.
    # ConvertFrom-Json turns an empty `properties: {}` into a PSCustomObject with no properties, and
    # under StrictMode `.PSObject.Properties.Name` on that throws "The property 'Name' cannot be
    # found on this object" - so v1.0.49, which set a property, deployed fine and v1.0.50, which set
    # none, failed. It failed safely, before the first byte was sent, but it failed with the server
    # already stopped and players waiting.
    $planned = @()
    $planProperties = @()
    if ($plan.PSObject.Properties.Name -contains 'properties' -and $null -ne $plan.properties) {
        $planProperties = @($plan.properties.PSObject.Properties | ForEach-Object { $_.Name })
    }
    if ($planProperties.Count) {
        foreach ($key in $planProperties) {
            $line = "$key=" + $plan.properties.$key
            if ($wantText -notmatch ("(?m)^" + [regex]::Escape($key) + "=")) {
                throw "server.properties no longer has key '$key' - nothing was sent"
            }
            $wantText = [regex]::Replace($wantText, "(?m)^" + [regex]::Escape($key) + "=.*$", { $line })
            $planned += $line
        }
    }
    if ($wantText -ne $stagedText) {
        Write-Host 'restage   the server rewrote server.properties on shutdown - re-applying our edits to its copy'
        [IO.File]::WriteAllText($propsPath, $wantText)
    }
    foreach ($line in $planned) { Write-Host ("property  {0}" -f $line) }

    # server.properties may lose nothing but the motd and the server's own date stamp.
    $keysBefore = @(($freshText -split "`r?`n") | Where-Object { $_ -match '^[a-z][a-z0-9.\-]*=' } | ForEach-Object { ($_ -split '=', 2)[0] })
    $keysAfter = @(([IO.File]::ReadAllText($propsPath) -split "`r?`n") | Where-Object { $_ -match '^[a-z][a-z0-9.\-]*=' } | ForEach-Object { ($_ -split '=', 2)[0] })
    if (Compare-Object $keysBefore $keysAfter) { throw 'server.properties gained or lost a key against what the server just held - nothing was sent' }
    Write-Host ("MATCH     server.properties {0} keys, motd -> v{1}" -f $keysAfter.Count, $version)
}
finally { Remove-Item -LiteralPath $fresh -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- what is about to be deleted
# Fetched now, after the shutdown, because the server writes its Voxy generation record as it
# stops - the copy Test-ServerDeployment took while it was up is already behind. This one is the
# rollback point, so it has to exist and be non-empty before anything is removed.
foreach ($rel in $afterBackup) {
    $dest = Join-Path $plan.backup (Split-Path $rel -Leaf)
    & $syncScript -Get ($rel -replace '\\', '/') -To $dest -Session $Session -MirrorRoot $DriveRoot | Out-Null
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf) -or (Get-Item -LiteralPath $dest).Length -eq 0) {
        throw "Could not back up $rel after the shutdown - nothing was sent and nothing was deleted"
    }
    Write-Host ("backup    {0} ({1} bytes) -> {2}" -f $rel, (Get-Item -LiteralPath $dest).Length, $plan.backup)
}

# ---------------------------------------------------------------- level.dat edits, on the post-shutdown copy
# The server rewrites level.dat as it stops, so the file is fetched only now, kept whole in the
# backup as the rollback point, edited by Edit-LevelData.py into the mirror, and sent with the rest.
# It is verified by the same read-back as every other file below.
$levelDataSend = @()
if ($levelDataEdits.Count) {
    $levelBackup = Join-Path $plan.backup 'level.dat'
    & $syncScript -Get 'world/level.dat' -To $levelBackup -Session $Session -MirrorRoot $DriveRoot | Out-Null
    if (-not (Test-Path -LiteralPath $levelBackup -PathType Leaf) -or (Get-Item -LiteralPath $levelBackup).Length -eq 0) {
        throw 'Could not back up world/level.dat after the shutdown - nothing was sent'
    }
    $levelLocal = Join-Path $DriveRoot 'world\level.dat'
    New-Item -ItemType Directory -Force -Path (Split-Path $levelLocal -Parent) | Out-Null
    $report = & python (Join-Path $PSScriptRoot 'Edit-LevelData.py') $levelBackup $levelLocal @levelDataEdits 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Edit-LevelData.py refused the edit - nothing was sent: $report" }
    foreach ($line in @($report)) { Write-Host ('leveldat  ' + $line) }
    $levelDataSend = @('world\level.dat')
}

# ---------------------------------------------------------------- nothing may travel that changed
# Staging and sending are separate runs now, so the plan's hashes are re-checked here rather than
# trusted. server.properties is exempt: it was just rebuilt from what the server held seconds ago,
# which is the whole point of the block above.
$sendFiles = @()
$bad = @()
foreach ($f in $plan.send) {
    $local = Join-Path $DriveRoot $f.rel
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { $bad += ($f.rel + ' (gone from the mirror)'); continue }
    if ($f.rel -ne 'server.properties') {
        $now = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLower()
        if ($now -ne $f.sha256) { $bad += ($f.rel + ' (changed since staging)'); continue }
    }
    $sendFiles += $f.rel
}
if ($bad.Count) { throw ('The staged files no longer match the plan: ' + ($bad -join '; ') + ' - re-stage.') }
Write-Host ("verified  {0} staged file(s) still match the plan" -f $sendFiles.Count)
$sendFiles += $levelDataSend

# ---------------------------------------------------------------- send it
Write-Host ''
# The ping again, because the outage is only proved for the moment it was taken and the checks above
# are not instant. A server that came back up between them would save its own state over this.
if (Test-ServerUp) { throw 'The server came back up while this was checking. Nothing was sent. Stop it and re-run.' }
Write-Host 'server    still down immediately before the first remote write'

& $syncScript -Push -Files $sendFiles -Remove (@($plan.remove) + $afterBackup) -Session $Session -MirrorRoot $DriveRoot | Out-Null

# ---------------------------------------------------------------- prove it landed
$readback = Join-Path $env:TEMP ('nbidal18-deploy-verify-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $readback | Out-Null
$remoteBad = @()
try {
    foreach ($rel in $sendFiles) {
        $to = Join-Path $readback ($rel -replace '[\\/]', '_')
        & $syncScript -Get ($rel -replace '\\', '/') -To $to -Session $Session -MirrorRoot $DriveRoot | Out-Null
        if (-not (Test-Path -LiteralPath $to)) { $remoteBad += ($rel + ' (not readable back)'); continue }
        $want = (Get-FileHash -LiteralPath (Join-Path $DriveRoot $rel) -Algorithm SHA256).Hash
        $got = (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash
        if ($want -ne $got) { $remoteBad += ($rel + ' (hash differs on the server)') }
        Write-Host ("{0}  {1}" -f $(if ($want -eq $got) { 'ON SERVER' } else { 'DIFFERS  ' }), $rel)
    }
}
finally { Remove-Item -LiteralPath $readback -Recurse -Force -ErrorAction SilentlyContinue }
if ($remoteBad.Count) { throw ('Deployed but did not verify on the server: ' + ($remoteBad -join '; ')) }

# A deletion is proved the only way SFTP allows: a fetch that fails. Sync-ServerMirror throws when
# WinSCP cannot get the file, which here is the answer wanted.
$stillThere = @()
$probe = Join-Path $env:TEMP ('nbidal18-deploy-probe-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $probe | Out-Null
try {
    foreach ($rel in $afterBackup) {
        $to = Join-Path $probe ($rel -replace '[\\/]', '_')
        $gone = $false
        try { & $syncScript -Get ($rel -replace '\\', '/') -To $to -Session $Session -MirrorRoot $DriveRoot *> $null }
        catch { $gone = $true }
        if (-not $gone -and (Test-Path -LiteralPath $to)) { $stillThere += $rel }
        Write-Host ("{0}  {1}" -f $(if ($gone -or -not (Test-Path -LiteralPath $to)) { 'DELETED  ' } else { 'STILL THERE' }), $rel)
    }
}
finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
if ($stillThere.Count) { throw ('Deployed, but these were not deleted from the server: ' + ($stillThere -join '; ')) }
# The probe's expected failure leaves WinSCP's non-zero exit code behind, and a caller reading
# $LASTEXITCODE would take a deploy that finished for one that did not. v1.0.61's deploy did.
$global:LASTEXITCODE = 0

# The plan is consumed. Leaving it would let a second run re-send a release that is already out,
# against a mirror that no longer matches it.
Remove-Item -LiteralPath $planPath -Force
Write-Host ''
Write-Host ("OK        {0} file(s) on the server and verified by hash, {1} jar(s) removed, {2} file(s) deleted after backup, {3} level.dat edit(s). Start it." -f $sendFiles.Count, @($plan.remove).Count, $afterBackup.Count, $levelDataEdits.Count)
