<#
    Pulls the live server's deployable state down to a local mirror, and pushes reviewed files back.

      scripts\Sync-ServerMirror.ps1 -Pull
      scripts\Sync-ServerMirror.ps1 -Push -Files 'mods\a.jar','config\b.properties'
      scripts\Sync-ServerMirror.ps1 -Push -Remove 'mods\superseded-helper.jar'

    Why this exists: `Y:` was a CloudMounter SFTP mount and that trial expired, so Deploy-LiveServer
    has no filesystem to write to. Every deploy since has been ad-hoc WinSCP commands typed once and
    shredded afterwards, because they carried the password inline - which means the one step that
    touches the live server is the only step with no script behind it.

    **No credential ever appears here.** WinSCP stores the session; this names it. Save the site once
    in the WinSCP GUI with "Save password" ticked and pass its name, or set NBIDAL18_WINSCP_SESSION.
    Nothing in this file, in the repo, or in the shell history is a secret, so it does not have to be
    destroyed after use.

    Pull writes into a mirror that Deploy-LiveServer can then run against with -DriveRoot, so the
    existing refusals - the digest check, the Server List Ping, the hash-verified backups - all still
    apply. This moves bytes; it decides nothing.
#>
[CmdletBinding(DefaultParameterSetName = 'Pull')]
param(
    [Parameter(ParameterSetName = 'Pull')]  [switch] $Pull,
    # Re-fetch only the two files the server rewrites by itself, skipping the 169 MB of mods. A
    # deploy pulls while the server is still serving players and stages against that, so by the
    # time it is stopped its own shutdown has rewritten server.properties and the policy - and
    # nothing else. This refreshes exactly those, in seconds, without a second full pull.
    [Parameter(ParameterSetName = 'Pull')]  [switch] $VolatileOnly,
    [Parameter(ParameterSetName = 'Push')]  [switch] $Push,
    # Read-only remote directory listing, for the things the mirror deliberately never copies - the
    # world above all. Diagnosing anything in there otherwise means typing WinSCP commands by hand,
    # which is how the one step that touches the server ended up with no script behind it.
    # Listing is safe while the server is running; it writes nothing.
    [Parameter(ParameterSetName = 'List')]  [string] $List,
    # Read-only fetch of one remote file to a scratch path, for the same reason as -List: reading a
    # log or a world-folder file to diagnose something should not mean hand-typed WinSCP.
    [Parameter(ParameterSetName = 'Get')]   [string] $Get,
    [Parameter(ParameterSetName = 'Get')]   [string] $To,
    # Rename a remote path. Added 2026-09-22 for resetting the End: moving a 2 GB dimension folder
    # aside is the only backup of it that is affordable, and it is instant and reversible where a
    # delete is neither. Named Move rather than folded into Push because it is not a copy and must
    # never be inferred - it is only ever used on a stopped server, by Reset-Dimension.ps1.
    [Parameter(ParameterSetName = 'Move')]  [string] $Move,
    [Parameter(ParameterSetName = 'Move')]  [string] $MoveTo,
    # Upload one named local file to one named remote path, the mirror image of -Get. Separate from
    # -Push on purpose: -Push takes mirror-relative paths and the world is deliberately not in the
    # mirror, so pushing a world file would mean inventing a mirror entry for something the mirror
    # exists to stay out of. Used by Reset-Dimension.ps1 for wover-generator.nbt, on a stopped
    # server, with the original kept locally first.
    [Parameter(ParameterSetName = 'Put')]   [string] $Put,
    [Parameter(ParameterSetName = 'Put')]   [string] $PutTo,
    [Parameter(ParameterSetName = 'Push')]  [string[]] $Files,
    # Deleting is named separately from copying and is never inferred. A superseded helper has to
    # go - two jars claiming one mod id and the loader picks one - but nothing here should ever
    # work out on its own what the server no longer needs.
    [Parameter(ParameterSetName = 'Push')]  [string[]] $Remove,
    [string] $Session = $env:NBIDAL18_WINSCP_SESSION,
    [string] $MirrorRoot,
    [string] $RemoteRoot = '/'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Session) {
    throw "No WinSCP session named. Pass -Session 'name' or set NBIDAL18_WINSCP_SESSION. Save the site in the WinSCP GUI first, with its password, so nothing has to be typed here."
}

$repo = Split-Path -Parent $PSScriptRoot
$packRoot = Split-Path -Parent $repo
if (-not $MirrorRoot) { $MirrorRoot = Join-Path $packRoot '_server-payload-cache' }
# Absolute from here on. WinSCP is opened in the temp folder (see LocalDirectory below), so a
# relative mirror such as `..\_server-payload-cache` - exactly how the hardcore deploy is
# typed - resolved against that folder, and the pull died in WinSCP with nothing to show for it.
#
# Against $PWD by hand: [IO.Path]::GetFullPath uses .NET's current directory, which PowerShell does
# not update on Set-Location, so a relative root resolved against the process's start directory.
if (-not [IO.Path]::IsPathRooted($MirrorRoot)) { $MirrorRoot = Join-Path $PWD.ProviderPath $MirrorRoot }
$MirrorRoot = [IO.Path]::GetFullPath($MirrorRoot).TrimEnd([char]92)

$winscp = @(
    "$env:LOCALAPPDATA\Programs\WinSCP\WinSCP.com",
    "$env:ProgramFiles\WinSCP\WinSCP.com",
    "${env:ProgramFiles(x86)}\WinSCP\WinSCP.com"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $winscp) { throw 'WinSCP.com not found. Install WinSCP, or add its folder here.' }

# WinSCP reads the script from a file; building it as one string keeps the quoting in one place.
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('option batch abort')
$lines.Add('option confirm off')
# WinSCP parses a session name as a URL token, so a literal "+" arrives as a space and the site
# is not found - "Gamehostbros Vanilla+" became "Gamehostbros Vanilla ". Percent-encode the three
# characters it interprets, "%" first so the escapes are not re-escaped.
$encoded = $Session.Replace('%', '%25').Replace('+', '%2B').Replace(' ', '%20')
# WinSCP prints a hint suggesting an inline sftp:// URL instead of a saved site. That is exactly
# what this avoids: the URL carries the password, the site name does not.
# Override the site's local directory at open time, not after.
#
# WinSCP saves whichever local folder the GUI was last pointed at INTO the site, and re-enters it
# while connecting. Browse somewhere in the GUI, delete that folder later, and every scripted run
# then aborts during open with "Error changing directory ... System Error. Code: 2" - long after the
# act that caused it and nowhere near this file. An `lcd` afterwards is too late; the failure
# happens before any command runs. Nothing here depends on the local working directory, since every
# path below is absolute.
$localDir = [IO.Path]::GetTempPath().TrimEnd([char]92)
$lines.Add("open `"$encoded`" -rawsettings LocalDirectory=`"$localDir`"")

if ($Pull) {
    if (-not (Test-Path -LiteralPath $MirrorRoot)) { New-Item -ItemType Directory -Path $MirrorRoot | Out-Null }
    # Only what a deploy reads or replaces. The world, playerdata and logs are deliberately absent:
    # they are large, they are not ours to move, and nothing here should ever be in a position to
    # write them back.
    foreach ($item in $(if ($VolatileOnly) { @() } else { @('mods', 'config') })) {
        $local = Join-Path $MirrorRoot $item
        # Emptied first, so every file is fetched rather than compared. WinSCP's synchronize skips a
        # local file that is NEWER than the remote one, and Deploy-LiveServer rehearses by writing
        # into this mirror - so every file a rehearsal touched was newer than the server's, and a
        # pull silently left the rehearsal's own output in place and called it the server's state.
        #
        # That is how a mirror came to report spreadFactor 7 while the server sat at 2. The next
        # deploy would have compared against that, found it already correct, and skipped the one
        # file the release existed to deliver. Re-fetching costs about sixty megabytes and takes
        # seconds; believing a stale mirror costs a release.
        if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Recurse -Force }
        New-Item -ItemType Directory -Path $local | Out-Null
        # -criteria=either (time or size), not size alone. The integrity policy is 352 bytes before
        # and after a release and the MOTD line keeps its length, so a size comparison skips exactly
        # the two files a deploy changes, and the mirror then reports our own writes back to us as
        # if they were the server's. That is how a rehearsal's output was once mistaken for the
        # live policy.
        #
        # Not -criteria=checksum: that makes WinSCP run a hashing command over SSH, and this host is
        # SFTP-only - it answers "Server refused to start a shell/command" and the pull fails.
        $lines.Add("synchronize local -delete -criteria=either `"$local`" `"$RemoteRoot$item`"")
    }
    # Fetched unconditionally rather than left to the directory sync. These two are what a deploy
    # is judged by, they are small, and both keep their byte count across a release - so any
    # criteria-based comparison is exactly the wrong tool for them.
    foreach ($file in @('server.properties', 'config/nbidal18-integrity.properties')) {
        # Built by splitting on the separator and joining part by part: no literal backslash, and
        # no regex, both of which have bitten this repo before.
        $target = $MirrorRoot
        foreach ($part in $file.Split([char]47)) { $target = Join-Path $target $part }
        $lines.Add("get `"$RemoteRoot$file`" `"$target`"")
    }
    Write-Host ("pull      {0} -> {1}" -f $(if ($VolatileOnly) { 'server.properties and the policy only' }
            else { 'mods, config and server.properties' }), $MirrorRoot)
}

if ($List) {
    $remote = $List.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
    if (-not $remote.StartsWith('/')) { $remote = $RemoteRoot + $remote }
    $lines.Add("ls `"$remote`"")
    Write-Host ("list      {0}" -f $remote)
}

if ($Move) {
    if (-not $MoveTo) { throw 'Pass -MoveTo with -Move. A move with no destination is not a default.' }
    $from = $Move.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
    if (-not $from.StartsWith('/')) { $from = $RemoteRoot + $from }
    $dest = $MoveTo.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
    if (-not $dest.StartsWith('/')) { $dest = $RemoteRoot + $dest }
    $lines.Add("mv `"$from`" `"$dest`"")
    Write-Host ("move      {0} -> {1}" -f $from, $dest)
}

if ($Put) {
    if (-not $PutTo) { throw 'Pass -PutTo with -Put. An upload destination is never inferred.' }
    if (-not (Test-Path -LiteralPath $Put -PathType Leaf)) { throw "No such local file: $Put" }
    $dest = $PutTo.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
    if (-not $dest.StartsWith('/')) { $dest = $RemoteRoot + $dest }
    $lines.Add("put `"$Put`" `"$dest`"")
    Write-Host ("put       {0} -> {1}" -f $Put, $dest)
}

if ($Get) {
    $remote = $Get.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
    if (-not $remote.StartsWith('/')) { $remote = $RemoteRoot + $remote }
    if (-not $To) { $To = Join-Path ([IO.Path]::GetTempPath()) (Split-Path $remote -Leaf) }
    $lines.Add("get `"$remote`" `"$To`"")
    Write-Host ("get       {0} -> {1}" -f $remote, $To)
}

if ($Push) {
    if (-not $Files -and -not $Remove) { throw 'Push needs -Files or -Remove: reviewed paths, relative to the mirror root.' }
    # A file inside a folder the server does not have yet (v1.0.86: config/controlify/server.json,
    # a mod's own folder that it only creates on its first boot) needs that folder made first, and
    # WinSCP's `put` does not make it. Its `mkdir` fails on a folder that already exists and a
    # failed line aborts the whole batch, so each parent is looked up on the server first, with a
    # listing of its own parent, and only a missing one gets a mkdir line ahead of the puts. The
    # roots the server always has (mods, config, world) are never touched.
    # Each lookup is a WinSCP login of its own, so a folder already found absent is not listed
    # for its children: everything under it is absent too and gets its mkdir straight away
    # (v1.0.89, from a day when a six-deep datapack tree cost a login per leaf folder).
    $ensured = New-Object System.Collections.Generic.HashSet[string]
    $absent = New-Object System.Collections.Generic.HashSet[string]
    foreach ($rel in $Files) {
        $parts = @($rel.Replace([IO.Path]::DirectorySeparatorChar, [char]47).Split([char]47))
        for ($depth = 2; $depth -lt $parts.Count; $depth++) {
            $dir = ($parts[0..($depth - 1)] -join '/')
            if (-not $ensured.Add($dir)) { continue }
            $parentOf = ($parts[0..($depth - 2)] -join '/')
            $leaf = $parts[$depth - 1]
            if (-not $absent.Contains($parentOf)) {
                $listing = & $PSCommandPath -List $parentOf -Session $Session -RemoteRoot $RemoteRoot 2>&1 | Out-String
                $present = ($listing -split "`n") | Where-Object { $_ -match ('^d\S+\s+.*\s' + [regex]::Escape($leaf) + '\s*$') }
                if ($present) { continue }
            }
            [void]$absent.Add($dir)
            $lines.Add("mkdir `"$RemoteRoot$dir`"")
            Write-Host ("mkdir     {0} (absent on the server)" -f $dir)
        }
    }
    foreach ($rel in $Files) {
        $local = Join-Path $MirrorRoot $rel
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { throw "Not in the mirror: $local" }
        # No literal backslash on purpose: this file is written from a shell where one collapses.
        $remote = $RemoteRoot + $rel.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
        $lines.Add("put `"$local`" `"$remote`"")
        Write-Host ("push      {0}" -f $rel)
    }
    foreach ($rel in $Remove) {
        $remote = $RemoteRoot + $rel.Replace([IO.Path]::DirectorySeparatorChar, [char]47)
        $lines.Add("rm `"$remote`"")
        Write-Host ("remove    {0}" -f $rel)
    }
}

$lines.Add('exit')

$scriptFile = Join-Path ([IO.Path]::GetTempPath()) ("nbidal18-winscp-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
[IO.File]::WriteAllText($scriptFile, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
try {
    # No /ini=nul here: the saved session lives in WinSCP's own configuration, so telling it to
    # ignore that is telling it the session does not exist.
    & $winscp /script=$scriptFile
    if ($LASTEXITCODE -ne 0) {
        # Deliberately does not name a cause. This used to assert the session name was wrong, and
        # spent a deploy window sending everyone to check a name that was correct - the actual
        # failure was a stale local directory saved into the site. WinSCP's own output is printed
        # above; read that rather than this line.
        throw "WinSCP exited $LASTEXITCODE - see its output above for the reason."
    }
}
finally {
    # The script file names a session, never a password - removed for tidiness, not for secrecy.
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
}

Write-Host 'OK        transfer complete'
