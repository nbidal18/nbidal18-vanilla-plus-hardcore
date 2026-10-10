<#
    Proves the final release detaches a player's instance from the channel - before it is published.

      scripts\Test-Detach.ps1              previous release = the last commit (what players have now)
      scripts\Test-Detach.ps1 -Keep        leave the throwaway instances for inspection

    Written for v1.0.24, the "unlink from github" release (owner, 2026-10-10). It is the one release
    that cannot be fixed afterwards: once a player's updater is detached, nothing we publish reaches
    them again. So this does not test the build in isolation - Test-LocalSync already does that - it
    walks the exact path a real player takes, end to end, against a local copy of the channel:

      1. EXISTING PLAYER. A throwaway instance is installed from the PREVIOUS release, using that
         release's own client ZIP and its own site, exactly as a player has it today.
      2. PRESS PLAY ON v1.0.24. The same instance syncs against the new site. The previous engine
         installs v1.0.24; the supervisor promotes the new engine and runs it in the same launch.
         Checked: the integrity helper and Better Compatibility Checker are gone, the engine on disk
         is the detached build, and the new engine really ran (it says so).
      3. THE CHANNEL DISAPPEARS. The local server is stopped and the URL points at a dead port. The
         player then adds a mod, deletes one of ours and edits a managed config. Pressing Play must
         exit 0 within seconds and leave all three changes exactly as made.
      4. A FRESH IMPORT OF v1.0.24's ZIP installs once while the channel is up, then detaches too.

    Nothing touches a real instance, a server or the published channel.
#>
[CmdletBinding()]
param(
    [int] $Port = 29181,
    [string] $PreviousCommit = 'HEAD',
    [switch] $Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$clientZip = (Get-Content -LiteralPath (Join-Path $repo 'CLIENT-ZIP.txt') -Raw).Trim()
$prefix = (Get-Content -LiteralPath (Join-Path $repo 'RELEASE-PREFIX.txt') -Raw).Trim()
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
$site = Join-Path $repo 'site'
. (Join-Path $PSScriptRoot 'Resolve-PackwizTool.ps1')
$packwiz = Resolve-PackwizTool -Release $release
$javaPath = Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-epsilon\bin\java.exe'
$detachedEngine = Join-Path $repo 'client\nbidal18-packwiz-updater.jar'
foreach ($required in @($site, $packwiz, $javaPath, $detachedEngine)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing: $required" }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('nbidal18-detach-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$failures = [Collections.Generic.List[string]]::new()
function Assert([bool] $ok, [string] $what) {
    if ($ok) { Write-Host ("  ok      {0}" -f $what) } else { Write-Host ("  FAIL    {0}" -f $what); $failures.Add($what) }
}

# The previous release's channel, exactly as committed - what the published channel served.
$prevSite = Join-Path $root 'previous-site'
$archive = Join-Path $root 'previous.zip'
& git -C $repo archive --format=zip -o $archive $PreviousCommit site
if ($LASTEXITCODE -ne 0) { throw "git archive of $PreviousCommit failed" }
Expand-Archive -LiteralPath $archive -DestinationPath $prevSite
$prevSite = Join-Path $prevSite 'site'
$prevVersion = ((Get-Content -LiteralPath (Join-Path $prevSite 'sync-manifest.json') -Raw) | ConvertFrom-Json).packVersion
Write-Host ("previous  v{0} from {1}" -f $prevVersion, $PreviousCommit)
Write-Host ("final     v{0} from site\" -f $version)

$server = $null
function Start-Channel([string] $dir) {
    $script:server = Start-Process -FilePath $packwiz -ArgumentList "serve --basic --port $Port" `
        -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $root 'serve.log') -RedirectStandardError (Join-Path $root 'serve.err')
    foreach ($i in 1..60) {
        try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/pack.toml" -UseBasicParsing -TimeoutSec 1 | Out-Null; return }
        catch { Start-Sleep -Milliseconds 200 }
    }
    throw "the local channel never answered on port $Port"
}
function Stop-Channel {
    if ($script:server -and -not $script:server.HasExited) { Stop-Process -Id $script:server.Id -Force }
    $script:server = $null
    Start-Sleep -Milliseconds 500
}
function Seed-Instance([string] $siteDir, [string] $minecraft) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path $minecraft | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $siteDir $clientZip))
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -notlike 'minecraft/*' -or $e.FullName.EndsWith('/')) { continue }
            $t = Join-Path $minecraft ($e.FullName.Substring(10).Replace('/', [IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Force -Path (Split-Path $t -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
        }
    } finally { $zip.Dispose() }
}
function Press-Play([string] $minecraft, [string] $label) {
    $env:INST_MC_DIR = $minecraft
    $env:NBIDAL18_PACK_URL = "http://127.0.0.1:$Port/pack.toml"
    $env:NBIDAL18_MANIFEST_URL = "http://127.0.0.1:$Port/sync-manifest.json"
    $env:NBIDAL18_HEADLESS_TEST = '1'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $javaPath -jar (Join-Path $minecraft 'nbidal18-packwiz-sync.jar') 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    $watch.Stop()
    Write-Host ("{0,-9} exit {1} in {2:N1} s" -f $label, $code, $watch.Elapsed.TotalSeconds)
    return [pscustomobject]@{ Code = $code; Text = ($out | Out-String); Seconds = $watch.Elapsed.TotalSeconds }
}
function Hash([string] $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

try {
    # ---- 1. an existing player on the previous release -------------------------------------
    Write-Host ''; Write-Host '1. existing player, installed from the previous release'
    $player = Join-Path $root 'player\minecraft'
    Seed-Instance $prevSite $player
    Start-Channel $prevSite
    $r = Press-Play $player 'install'
    Stop-Channel
    Assert ($r.Code -eq 0) "v$prevVersion installs"
    Assert ([bool](Get-ChildItem (Join-Path $player 'mods') -Filter 'nbidal18-integrity-*.jar' -ErrorAction SilentlyContinue)) 'the previous release has the integrity helper (the starting point is real)'

    # ---- 2. press Play on the final release ---------------------------------------------------
    Write-Host ''; Write-Host "2. the same instance presses Play on v$version"
    Start-Channel $site
    $r = Press-Play $player 'update'
    Stop-Channel
    Assert ($r.Code -eq 0) 'the update exits 0, so Minecraft would start'
    Assert ($r.Text -match 'Detached from the update channel') 'the new engine ran in the same launch and detached'
    Assert (-not (Get-ChildItem (Join-Path $player 'mods') -Filter 'nbidal18-integrity-*.jar' -ErrorAction SilentlyContinue)) 'integrity helper removed'
    Assert (-not (Get-ChildItem (Join-Path $player 'mods') -Filter 'better-compatability-checker-*.jar' -ErrorAction SilentlyContinue)) 'Better Compatibility Checker removed'
    Assert (-not (Test-Path -LiteralPath (Join-Path $player 'config\bcc-common.json'))) 'its config removed'
    Assert ((Hash (Join-Path $player 'nbidal18-packwiz-updater.jar')) -eq (Hash $detachedEngine)) 'the engine on disk is the detached build'

    # ---- 3. the channel disappears and the player changes things ------------------------------
    Write-Host ''; Write-Host '3. channel gone; the player adds a mod, deletes one of ours, edits a config'
    $extra = Join-Path $player 'mods\players-own-mod.jar'
    [IO.File]::WriteAllBytes($extra, [byte[]](80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    $victim = Get-ChildItem (Join-Path $player 'mods') -Filter 'wakes-*.jar' | Select-Object -First 1
    if (-not $victim) { $victim = Get-ChildItem (Join-Path $player 'mods') -Filter '*.jar' | Where-Object Name -notlike 'nbidal18-*' | Select-Object -First 1 }
    Remove-Item -LiteralPath $victim.FullName -Force
    $cfg = Get-ChildItem (Join-Path $player 'config') -Filter '*.json' | Select-Object -First 1
    Add-Content -LiteralPath $cfg.FullName -Value '' -NoNewline
    [IO.File]::AppendAllText($cfg.FullName, "`n// edited by the player`n")
    $cfgHash = Hash $cfg.FullName
    $env:NBIDAL18_PACK_URL = "http://127.0.0.1:1/pack.toml"
    $r = Press-Play $player 'offline'
    Assert ($r.Code -eq 0) 'Play still exits 0 with no channel at all'
    Assert ($r.Seconds -lt 15) ('and promptly ({0:N1} s), never waiting on the network' -f $r.Seconds)
    Assert (Test-Path -LiteralPath $extra) "the player's own mod is left in place"
    Assert (-not (Test-Path -LiteralPath $victim.FullName)) ("the mod the player deleted ({0}) stays deleted" -f $victim.Name)
    Assert ((Hash $cfg.FullName) -eq $cfgHash) ("the player's edit to {0} is untouched" -f $cfg.Name)

    # ---- 4. a fresh import of the final ZIP installs once, then detaches -----------------------
    Write-Host ''; Write-Host "4. a fresh import of v$version's client ZIP"
    $fresh = Join-Path $root 'fresh\minecraft'
    Seed-Instance $site $fresh
    Start-Channel $site
    $r = Press-Play $fresh 'first'
    Stop-Channel
    Assert ($r.Code -eq 0) 'the first launch installs'
    Assert ((Get-ChildItem (Join-Path $fresh 'mods') -Filter '*.jar').Count -gt 100) ('{0} mods arrived' -f (Get-ChildItem (Join-Path $fresh 'mods') -Filter '*.jar').Count)
    $env:NBIDAL18_PACK_URL = "http://127.0.0.1:1/pack.toml"
    $r = Press-Play $fresh 'second'
    Assert ($r.Code -eq 0 -and $r.Text -match 'Detached from the update channel') 'the second launch is detached'
}
finally {
    Stop-Channel
    Remove-Item Env:INST_MC_DIR, Env:NBIDAL18_PACK_URL, Env:NBIDAL18_MANIFEST_URL, Env:NBIDAL18_HEADLESS_TEST -ErrorAction SilentlyContinue
    if ($Keep) { Write-Host ("kept      {0}" -f $root) } else { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($failures.Count -gt 0) { throw ("{0} check(s) failed: {1}" -f $failures.Count, ($failures -join '; ')) }
Write-Host 'OK        an existing player detaches on the first Play, keeps every change afterwards,'
Write-Host '          and launches with the channel gone; a fresh import installs once, then detaches.'
