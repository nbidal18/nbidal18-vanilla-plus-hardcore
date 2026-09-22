<#
    Reports which published config files a real, played instance writes to after syncing.

      scripts\Test-ConfigStability.ps1
      scripts\Test-ConfigStability.ps1 -InstancePath '...\instances\other\minecraft'

    **Run it against an instance that has actually been played.** A fresh install has not yet had the
    chance to rewrite anything, so it always passes and proves nothing.

    Hash enforcement only works on files the game leaves alone. A config its own mod rewrites during
    startup is rewritten *after* the pre-launch updater has run, so the moment a mod update reorders
    a key or adds a field, every player is refused at login - and reopening the game cannot clear it,
    because the game rewrites it again. That is the shape of the 1.21.1 pack's worst lockout.

    It reports three things:

      touched  the file's timestamp moved after the sync, so the mod writes it at startup. Any
               gameplay-class file here must appear in `rewrittenAtRuntime`. That list is a watch
               list, not an exemption: the file stays enforced, and the entry records that it has to
               be published in the exact form the mod writes back.
      drifted  the content actually differs from what was published. A gameplay file here is an
               active lockout - republish it from a played instance so the mod's own serialisation
               is what ships.
      extra    an unmanaged file appeared under an exact root.

    Compared against the manifest the instance actually installed, not the current build. The
    question is "did the game change anything after syncing", which is about that instance and that
    sync; using a freshly built manifest makes every version cut look like drift.
#>
[CmdletBinding()]
param(
    [string] $InstancePath = "$env:APPDATA\PrismLauncher\instances\nbidal18-vanilla-plus-client\minecraft"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$buildManifestPath = Join-Path $repo 'site\sync-manifest.json'
$classificationPath = Join-Path $PSScriptRoot 'config-classification.json'
foreach ($required in @($buildManifestPath, $classificationPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing input: $required" }
}
if (-not (Test-Path -LiteralPath $InstancePath -PathType Container)) {
    throw "No such instance directory: $InstancePath"
}

$syncStamp = Join-Path $InstancePath '.nbidal18-packwiz\last-successful-manifest.json'
if (-not (Test-Path -LiteralPath $syncStamp -PathType Leaf)) {
    throw "This instance has never completed a sync: $syncStamp"
}
# Two seconds of slack: the updater writes the stamp and any repaired files in the same pass.
$syncedAt = (Get-Item -LiteralPath $syncStamp).LastWriteTimeUtc.AddSeconds(2)

$manifest = [IO.File]::ReadAllText($syncStamp, [Text.Encoding]::UTF8) | ConvertFrom-Json
$buildManifest = [IO.File]::ReadAllText($buildManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$classification = [IO.File]::ReadAllText($classificationPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$rules = @($classification.rules + $classification.outsideConfig)

# This line records runtime rewrites as one measured list, not as a flag on each rule.
$declaredRewritten = @{}
foreach ($path in $classification.rewrittenAtRuntime) { $declaredRewritten[$path] = $true }

# Longest matching prefix wins; a rule ending in / matches a subtree.
function Resolve-Rule([string] $relative) {
    $best = $null
    foreach ($rule in $rules) {
        $matched = if ($rule.match.EndsWith('/')) {
            $relative.StartsWith($rule.match, [StringComparison]::Ordinal)
        }
        else { $relative -ceq $rule.match }
        if ($matched -and ($null -eq $best -or $rule.match.Length -gt $best.match.Length)) { $best = $rule }
    }
    return $best
}

function Get-NormalizedTextSha256([string] $path) {
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

$normalized = @{}
foreach ($entry in $manifest.normalizedTextFiles) { $normalized[$entry.path] = $entry.sha256 }

$touched = [Collections.Generic.List[object]]::new()
$drifted = [Collections.Generic.List[object]]::new()

foreach ($entry in $manifest.files) {
    if ($entry.path -notlike 'config/*') { continue }
    $local = Join-Path $InstancePath $entry.path.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { continue }

    $rule = Resolve-Rule $entry.path
    $class = if ($null -eq $rule) { 'UNCLASSIFIED' } else { $rule.class }
    $declared = $declaredRewritten.ContainsKey($entry.path)

    if ((Get-Item -LiteralPath $local).LastWriteTimeUtc -gt $syncedAt) {
        $touched.Add([pscustomobject]@{ Path = $entry.path; Class = $class; Declared = $declared })
    }

    if ($normalized.ContainsKey($entry.path)) {
        $expected = $normalized[$entry.path]
        $actual = Get-NormalizedTextSha256 $local
    }
    else {
        $expected = $entry.sha256
        $actual = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($actual -ne $expected) {
        $drifted.Add([pscustomobject]@{ Path = $entry.path; Class = $class; Declared = $declared })
    }
}

$managed = @{}
foreach ($entry in $manifest.files) { $managed[$entry.path.ToLowerInvariant()] = $true }
foreach ($allowed in $manifest.localAllowed) { $managed[$allowed.ToLowerInvariant()] = $true }
$extra = [Collections.Generic.List[string]]::new()
foreach ($root in $manifest.exactRoots) {
    $rootPath = Join-Path $InstancePath $root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    # config/ tolerates unmanaged files by design - config libraries write their own during init -
    # so reporting them all would bury the roots where an extra file really is an intruder.
    if ($manifest.extraTolerantRoots -contains $root) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force) {
        $relative = $file.FullName.Substring($InstancePath.Length).TrimStart('\').Replace('\', '/')
        if (-not $managed.ContainsKey($relative.ToLowerInvariant())) { $extra.Add($relative) }
    }
}

Write-Host "instance  $InstancePath"
Write-Host "synced    $syncedAt UTC"
Write-Host ("version   instance {0}, build {1}" -f $manifest.packVersion, $buildManifest.packVersion)
if ($manifest.packVersion -ne $buildManifest.packVersion) {
    Write-Host '          the instance is behind the build, so it is checked against its own manifest'
}
Write-Host ''
Write-Host ("rewritten after the sync: {0}" -f $touched.Count)
foreach ($item in $touched | Sort-Object Class, Path) {
    $flag = if ($item.Class -eq 'gameplay' -and -not $item.Declared) { '   <-- NOT DECLARED' } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $item.Class, $item.Path, $flag)
}
Write-Host ''
Write-Host ("content differs from the published copy: {0}" -f $drifted.Count)
foreach ($item in $drifted | Sort-Object Class, Path) { Write-Host ("  [{0}] {1}" -f $item.Class, $item.Path) }
Write-Host ''
Write-Host ("unmanaged files under an enforced root: {0}" -f $extra.Count)
foreach ($item in $extra | Sort-Object) { Write-Host "  $item" }
Write-Host ''

# A gameplay file the game rewrites is a lockout waiting for the next mod update, so it must be
# declared. A support or player file is expected to be rewritten and needs no declaration.
$undeclared = @($touched | Where-Object { $_.Class -eq 'gameplay' -and -not $_.Declared })
$lockouts = @($drifted | Where-Object { $_.Class -eq 'gameplay' })
$unclassified = @(($touched + $drifted) | Where-Object { $_.Class -eq 'UNCLASSIFIED' })

if ($unclassified.Count) {
    throw ('Not classified at all: ' + (($unclassified.Path | Sort-Object -Unique) -join ', '))
}
if ($lockouts.Count) {
    throw ('These enforced gameplay configs no longer match the published copy and will refuse ' +
        'every login: ' + (($lockouts.Path | Sort-Object -Unique) -join ', '))
}
if ($undeclared.Count) {
    throw ('These gameplay configs are rewritten by their mod at startup but are missing from ' +
        'rewrittenAtRuntime in config-classification.json: ' +
        (($undeclared.Path | Sort-Object -Unique) -join ', '))
}
if ($extra.Count) {
    throw ('Unmanaged files under an enforced root - the integrity helper will refuse a login: ' +
        (($extra | Sort-Object) -join ', '))
}

$gameplayTouched = @($touched | Where-Object { $_.Class -eq 'gameplay' })
Write-Host ('OK        {0} enforced configs are rewritten at startup and all are declared; ' -f $gameplayTouched.Count)
Write-Host '          none of them drifted, and no unmanaged file appeared under an enforced root'
