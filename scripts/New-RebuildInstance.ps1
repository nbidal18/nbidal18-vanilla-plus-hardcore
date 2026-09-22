<#
.SYNOPSIS
    Create the clean Prism instance the v2.0.0 rebuild is built in: vanilla plus Fabric Loader, and
    nothing else.

.DESCRIPTION
    The rebuild's method, decided by the owner 2026-09-14 and restated 2026-09-21, is to start from a
    bare game and add one mod at a time, auditing each before the next goes in. That needs an instance
    that is genuinely empty - not the live client instance with its mods removed, which carries a
    packwiz pre-launch sync that would put all 177 back on the next launch.

    This script builds that instance from the versions the channel already states, so it cannot drift
    from the pack:

      MINECRAFT.txt  the game version
      LOADER.txt     the Fabric Loader version

    Nothing is downloaded. Prism's own metadata for those versions has to be present already, which it
    is whenever the live instance has been launched. The LWJGL version is read out of Prism's metadata
    for the game version rather than assumed.

    The instance deliberately has NO PreLaunchCommand. The live instance runs the packwiz sync there,
    and an empty instance that syncs itself is not an empty instance.

.PARAMETER InstanceName
    Prism instance folder to create. Defaults to nbidal18-rebuild - deliberately not the live one.

.PARAMETER Force
    Delete and recreate an existing instance of that name. Refuses without this.

.EXAMPLE
    .\New-RebuildInstance.ps1
    .\New-RebuildInstance.ps1 -Force
#>
[CmdletBinding()]
param(
    [string] $InstanceName = 'nbidal18-rebuild',
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$prismRoot = Join-Path $env:APPDATA 'PrismLauncher'

# ---------------------------------------------------------------- versions, from the channel's files
foreach ($f in @('MINECRAFT.txt', 'LOADER.txt')) {
    $p = Join-Path $repoRoot $f
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing version file: $p" }
}
$mcVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'MINECRAFT.txt') -Raw).Trim()
$loaderVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'LOADER.txt') -Raw).Trim()
Write-Host "Game   $mcVersion   (from MINECRAFT.txt)"
Write-Host "Loader $loaderVersion  (from LOADER.txt)"

# ---------------------------------------------------------------- Prism metadata must already be here
$mcMeta = Join-Path $prismRoot "meta\net.minecraft\$mcVersion.json"
$loaderMeta = Join-Path $prismRoot "meta\net.fabricmc.fabric-loader\$loaderVersion.json"
$intermediaryMeta = Join-Path $prismRoot "meta\net.fabricmc.intermediary\$mcVersion.json"
foreach ($m in @($mcMeta, $loaderMeta, $intermediaryMeta)) {
    if (-not (Test-Path -LiteralPath $m)) {
        throw "Prism has no metadata for this component: $m`n" +
              "Launch the live instance once so Prism fetches it, then run this again."
    }
}

# LWJGL is a dependency of the game version; read which one rather than assuming a number
$meta = Get-Content -LiteralPath $mcMeta -Raw | ConvertFrom-Json
$lwjglVersion = $null
if ($meta.PSObject.Properties.Name -contains 'requires') {
    foreach ($r in $meta.requires) {
        if ($r.uid -eq 'org.lwjgl3') {
            $lwjglVersion = if ($r.PSObject.Properties.Name -contains 'suggests') { $r.suggests } else { $r.equals }
        }
    }
}
if (-not $lwjglVersion) { throw "Could not read the LWJGL version required by Minecraft $mcVersion from $mcMeta" }
Write-Host "LWJGL  $lwjglVersion  (from Prism's metadata for $mcVersion)"

# ---------------------------------------------------------------- the java the build already uses
# Deliberately the same runtime Build-FirstPartyMods.ps1 compiles with, so the instance a mod is
# audited in is the instance it was built against.
$javaw = Join-Path $prismRoot 'java\java-runtime-epsilon\bin\javaw.exe'
if (-not (Test-Path -LiteralPath $javaw)) { throw "Missing Java runtime: $javaw" }

# ---------------------------------------------------------------- create
$instanceRoot = Join-Path $prismRoot "instances\$InstanceName"
if (Test-Path -LiteralPath $instanceRoot) {
    if (-not $Force) {
        throw "Instance already exists: $instanceRoot`nRe-run with -Force to replace it."
    }
    Write-Host "Removing existing instance (-Force)" -ForegroundColor Yellow
    Remove-Item -LiteralPath $instanceRoot -Recurse -Force
}

$minecraftDir = Join-Path $instanceRoot 'minecraft'
New-Item -ItemType Directory -Path (Join-Path $minecraftDir 'mods') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $minecraftDir 'config') -Force | Out-Null

$pack = [ordered]@{
    components = @(
        [ordered]@{ cachedName = 'LWJGL 3'; cachedVersion = $lwjglVersion; dependencyOnly = $true
                    uid = 'org.lwjgl3'; version = $lwjglVersion }
        [ordered]@{ cachedName = 'Minecraft'
                    cachedRequires = @([ordered]@{ suggests = $lwjglVersion; uid = 'org.lwjgl3' })
                    cachedVersion = $mcVersion; important = $true
                    uid = 'net.minecraft'; version = $mcVersion }
        [ordered]@{ cachedName = 'Intermediary Mappings'
                    cachedRequires = @([ordered]@{ equals = $mcVersion; uid = 'net.minecraft' })
                    cachedVersion = $mcVersion; dependencyOnly = $true
                    uid = 'net.fabricmc.intermediary'; version = $mcVersion }
        [ordered]@{ cachedName = 'Fabric Loader'
                    cachedRequires = @([ordered]@{ uid = 'net.fabricmc.intermediary' })
                    cachedVersion = $loaderVersion
                    uid = 'net.fabricmc.fabric-loader'; version = $loaderVersion }
    )
    formatVersion = 1
}
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $instanceRoot 'mmc-pack.json'),
                        ($pack | ConvertTo-Json -Depth 8), $utf8NoBom)

# No PreLaunchCommand on purpose - see the description.
$cfg = @(
    '[General]'
    'AutomaticJava=false'
    'ConfigVersion=1.2'
    'IgnoreJavaCompatibility=false'
    'InstanceType=OneSix'
    'JoinServerOnLaunch=false'
    'LogPrePostOutput=true'
    'ManagedPack=false'
    'MaxMemAlloc=8192'
    'MinMemAlloc=2048'
    "name=$InstanceName"
    'OverrideJavaLocation=true'
    'OverrideMemory=true'
    "JavaPath=$($javaw -replace '\\', '/')"
    'UseAccountForInstance=false'
    'notes=Clean room for the v2.0.0 rebuild. One mod at a time; see docs/archive/rebuild.md. No packwiz sync on purpose.'
) -join "`n"
[IO.File]::WriteAllText((Join-Path $instanceRoot 'instance.cfg'), $cfg + "`n", $utf8NoBom)

Write-Host ''
Write-Host "Created $instanceRoot" -ForegroundColor Green
Write-Host "  mods/   empty - this is the point"
Write-Host "  no PreLaunchCommand, so nothing syncs the pack back in"
Write-Host ''
Write-Host "Next: Fabric API, then the optimisation layer, one at a time, each written into"
Write-Host "      docs/archive/rebuild.md before the next goes in."
