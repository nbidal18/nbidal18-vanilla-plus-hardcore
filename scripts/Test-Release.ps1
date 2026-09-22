<#
    Works out what this release actually changed, and runs only the tests that change can break.

      scripts\Test-Release.ps1              run them
      scripts\Test-Release.ps1 -WhatIf      say what it would run, and why
      scripts\Test-Release.ps1 -All         run everything regardless

    Run it after Build-Release.ps1.

    **Why this exists.** The full suite is about eight minutes: two client launches, a dedicated
    server boot, a sync test. Running all of it to change one integer in one config file is how a
    two-minute edit becomes a ten-minute one, and it trains everybody to skip tests by hand instead -
    which is worse than a suite that is honest about what it needs.

    The decision comes from a diff of this release's published tree against the previous release's,
    not from judgement. A jar changed, so the client has to boot; only a config changed, so it only
    has to smoke-start. Judgement is what skipped Test-ClientLaunch for "just a resource pack" in
    v1.0.6 and shipped a core shader that blanked every inventory slot.

    **It reports what it skipped and why.** A suite that silently runs less is indistinguishable
    from one that is broken.

    **What it cannot see: changes that live outside the release folder.** Two of them:

      * **a re-classification.** Moving a config file between gameplay, support and player changes
        how the updater treats it while the published bytes stay identical, and the release folders
        do not record the classification. The build still refuses while anything is unclassified, so
        what this misses is a file whose ruling changed, not one that never had one.
      * **an edit to the updater itself** - a new seed, a new retired-files token, a change to how
        files are preserved. `Nbidal18PackwizSync.java` is in the repo, not in the release, and its
        jar is rebuilt every release either way, so a diff of the published trees cannot tell the
        difference between a rebuild and a rewrite.

    Both mean running with `-All`. Test-LocalSync is the test that covers them, and it is the one
    that found a latent lockout shipping since v1.0.0.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot,
    # Jars this release puts on the server for the first time. The dedicated-server test is implied
    # by a changed shared jar, but a genuinely new server mod cannot be inferred - same reason
    # Test-ServerDeployment makes it a named decision.
    [string[]] $AddMods = @(),
    [switch] $All,
    [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$packRoot = Split-Path -Parent $repo
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path $packRoot "$prefix$version" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

# Taken from the folder being tested, not from PACK-VERSION.txt. They are the same for a normal run,
# but -ReleaseRoot pointed at an older release has to compare against what came before *it* - reading
# the current version here compared v1.0.41 against v1.0.43 and called two unrelated jars a change.
$leaf = Split-Path $ReleaseRoot -Leaf
if ($leaf -notmatch '^v\.(\d+)\.(\d+)\.(\d+)$') { throw "Not a release folder name: $leaf" }
$subject = [version]::new([int] $Matches[1], [int] $Matches[2], [int] $Matches[3])

# The previous release is the newest v.* that is not this one, ordered properly rather than
# alphabetically - "v.1.0.9" sorts after "v.1.0.44" as text, which would compare against the wrong
# release and report every jar as changed.
$versions = @(Get-ChildItem -LiteralPath $packRoot -Directory -Filter 'v.*' |
        ForEach-Object {
            $parts = $_.Name.Substring(2) -split '\.'
            if ($parts.Count -ne 3) { return }
            [pscustomobject]@{
                Name = $_.Name
                Sort = [version]::new([int] $parts[0], [int] $parts[1], [int] $parts[2])
                Path = $_.FullName
            }
        } | Where-Object { $_ -and $_.Sort -lt $subject } | Sort-Object Sort)

Write-Host ("release   {0}" -f $leaf)
if (-not $versions.Count) {
    Write-Host 'previous  none - first release, so everything is new'
}
$previous = if ($versions.Count) { $versions[-1] } else { $null }
if ($previous) { Write-Host ("previous  {0}" -f $previous.Name) }

# ---------------------------------------------------------------- what changed
function Get-Tree([string] $root) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char]92).Replace([char]92, '/')
        $map[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $map
}

$clientNow = Get-Tree (Join-Path $ReleaseRoot '3. modpack\client')
$clientWas = if ($previous) { Get-Tree (Join-Path $previous.Path '3. modpack\client') } else { @{} }

$changed = New-Object Collections.Generic.List[string]
foreach ($path in $clientNow.Keys) {
    if (-not $clientWas.ContainsKey($path) -or $clientWas[$path] -ne $clientNow[$path]) { $changed.Add($path) }
}
foreach ($path in $clientWas.Keys) {
    if (-not $clientNow.ContainsKey($path)) { $changed.Add($path) }
}

$byArea = @{ mods = @(); config = @(); resourcepacks = @(); shaderpacks = @(); other = @() }
$routine = @()
foreach ($path in $changed) {
    # The integrity helper is regenerated and renamed on every single release, and bcc-common.json
    # carries the version string - so both differ every time, by construction rather than because
    # anybody changed anything. Counting them as changes would mean "a mod changed" was always true
    # and this script would never skip a thing, which is the same as not having it.
    #
    # They are not skipped as tests, only as *evidence*: a smoke start still runs on every release,
    # and Build-Release already refuses if the helper's version disagrees with the pack's.
    if ($path -like 'mods/nbidal18-integrity-*.jar' -or $path -eq 'config/bcc-common.json') {
        $routine += $path
        continue
    }
    $area = ($path -split '/')[0]
    if ($byArea.ContainsKey($area)) { $byArea[$area] += $path } else { $byArea['other'] += $path }
}

Write-Host ''
if ($routine.Count) {
    Write-Host ("routine   {0} file(s) that change every release (helper jar, version stamp)" -f $routine.Count)
}
if (-not $changed.Count) {
    Write-Host 'changed   nothing under 3. modpack\client - this release publishes no new content'
}
foreach ($area in @('mods', 'config', 'resourcepacks', 'shaderpacks', 'other')) {
    if ($byArea[$area].Count) {
        Write-Host ("changed   {0,-14} {1} file(s)" -f $area, $byArea[$area].Count)
        foreach ($path in @($byArea[$area] | Sort-Object | Select-Object -First 6)) {
            Write-Host ("            {0}" -f $path)
        }
        if ($byArea[$area].Count -gt 6) {
            Write-Host ("            ... and {0} more" -f ($byArea[$area].Count - 6))
        }
    }
}

# A config file appearing or disappearing changes what the updater has to install, preserve and
# classify. A value edited inside a file that was already there does not - which is the whole point
# of this script, and the case that should cost a smoke start and nothing more.
$configSetChanged = $false
foreach ($path in $changed) {
    if ($path -notlike 'config/*') { continue }
    if (-not $clientNow.ContainsKey($path) -or -not $clientWas.ContainsKey($path)) {
        $configSetChanged = $true
        break
    }
}

# ---------------------------------------------------------------- what that means
$run = [ordered]@{}
$skip = [ordered]@{}

$modsChanged = $byArea['mods'].Count -gt 0
$anyContent = $changed.Count -gt 0

if ($All) {
    $run['Test-LocalSync'] = 'forced by -All'
    $run['Test-ClientLaunch'] = 'forced by -All'
    $run['Test-DedicatedServer'] = 'forced by -All'
}
else {
    # Anything published at all gets a smoke start. It is the cheapest test here and the only one
    # that has ever caught a resource pack breaking the game - twice.
    if ($anyContent) { $run['Test-ClientLaunch'] = 'published content changed' }
    else { $skip['Test-ClientLaunch'] = 'nothing published changed' }

    if ($modsChanged -or $configSetChanged) {
        $run['Test-LocalSync'] = $(if ($modsChanged) { 'a mod jar changed' } else { 'a config file was added or removed' })
    }
    else {
        $skip['Test-LocalSync'] = 'no jar changed and no config file appeared or vanished'
    }

    # Only mods can stop the server booting. A client-only config or a resource pack cannot, and the
    # server test is the slowest thing here.
    if ($modsChanged -or $AddMods.Count) {
        $run['Test-DedicatedServer'] = $(if ($AddMods.Count) { 'a new server-side mod was named' } else { 'a mod jar changed' })
    }
    else {
        $skip['Test-DedicatedServer'] = 'no mod changed, so the server cannot boot differently'
    }
}

Write-Host ''
foreach ($name in $run.Keys) { Write-Host ("will run  {0,-22} {1}" -f $name, $run[$name]) }
foreach ($name in $skip.Keys) { Write-Host ("skipping  {0,-22} {1}" -f $name, $skip[$name]) }

if ($WhatIf) {
    Write-Host ''
    Write-Host 'Dry run. Re-run without -WhatIf to run them.'
    return
}
if (-not $run.Count) {
    Write-Host ''
    Write-Host 'OK        nothing published changed, so there is nothing to test.'
    return
}

# ---------------------------------------------------------------- run them
$mirror = Join-Path $packRoot '_server-payload-cache'
foreach ($name in $run.Keys) {
    Write-Host ''
    Write-Host ("== {0}" -f $name)
    $script = Join-Path $PSScriptRoot ($name + '.ps1')
    switch ($name) {
        'Test-DedicatedServer' { & $script -DriveRoot $mirror -AddMods $AddMods }
        default { & $script }
    }
    # $LASTEXITCODE is only set once a native process has run, and every test here is a PowerShell
    # script - so after the first one it may not exist at all, and StrictMode throws on reading an
    # undefined variable rather than treating it as null. The tests already throw on failure through
    # $ErrorActionPreference, so this is a backstop and must not be the thing that fails the run.
    $exit = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($exit -ne 0) { throw "$name failed with exit code $exit" }
}

Write-Host ''
Write-Host ("OK        {0} test(s) run, {1} skipped as not applicable to what changed."   -f $run.Count, $skip.Count)
