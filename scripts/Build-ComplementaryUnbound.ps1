<#
    Rebuilds the pack's Complementary Unbound: upstream + Euphoria Patches, glowing ores removed, the mob
    hurt flash made a toggle (off by default).

      scripts\Build-ComplementaryUnbound.ps1 -InstanceName <prism instance>     build it into the current release

    Owner, 2026-09-15: "complimentary unbound shaders with glowing ores enforced off", and "make sure it
    has a flashing mobs setting and turn it off, not enforced off tho". Owner, 2026-09-26: "lets get
    euphoria patches too, check if anything needs enforcing such as glowing ores, other similars which
    may be cheating".

    Euphoria Patches is applied by its own mod, which reads the upstream zip from shaderpacks/ and writes
    a patched FOLDER beside it at client start. That folder is what ships here - never the mod, because
    shaderpacks/ is an exact-match root and a folder written at runtime would be deleted by the updater
    on the next launch. So this script:

      1. builds a throwaway client source holding only the patcher jar and the upstream zip (both from the
         pack's source folder, upstream/), and starts it once with Test-ClientLaunch -ClientSource;
      2. takes the patched folder the patcher wrote into the throwaway's shaderpacks/;
      3. runs build_complementary.py on it, which makes the pack's edits and writes the zip and its
         settings sidecar into the release, with pinned timestamps so the result is reproducible.

    The upstream zip is checked against Modrinth's published SHA-512 by the builder; the patcher checks
    the zip itself before it will patch, so a wrong upstream stops at step 1.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot,
    # The Prism instance whose launcher metadata Test-ClientLaunch reads for the runtime (read only).
    [string] $InstanceName = 'nbidal18-vanilla-plus-client'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$packVersion = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path (Split-Path -Parent $repo) "$prefix$packVersion" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

$source = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Complementary-Unbound'
$builder = Join-Path $source 'build_complementary.py'
$upstream = Join-Path $source 'upstream'
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "Missing input: $builder" }
$zip = @(Get-ChildItem -LiteralPath $upstream -File -Filter 'ComplementaryUnbound_*.zip')
$patcher = @(Get-ChildItem -LiteralPath $upstream -File -Filter 'EuphoriaPatcher-*.jar')
if ($zip.Count -ne 1) { throw "upstream\ must hold exactly one ComplementaryUnbound_*.zip, found $($zip.Count)" }
if ($patcher.Count -ne 1) { throw "upstream\ must hold exactly one EuphoriaPatcher-*.jar, found $($patcher.Count)" }

# 1. A client source with nothing but the two inputs. Test-ClientLaunch stages it into its usual
#    throwaway, reaches the title screen and leaves the directory behind (-KeepGameDir).
$scratch = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-euphoria-source'
if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $scratch 'mods'), (Join-Path $scratch 'shaderpacks'), (Join-Path $scratch 'config') | Out-Null
Copy-Item -LiteralPath $patcher[0].FullName -Destination (Join-Path $scratch 'mods')
Copy-Item -LiteralPath $zip[0].FullName -Destination (Join-Path $scratch 'shaderpacks')
Copy-Item -LiteralPath (Join-Path $ReleaseRoot '3. modpack\client\options.txt') -Destination (Join-Path $scratch 'options.txt')
Write-Host ("patching  {0} with {1} in a throwaway client" -f $zip[0].Name, $patcher[0].Name)
& (Join-Path $PSScriptRoot 'Test-ClientLaunch.ps1') -InstanceName $InstanceName -ClientSource $scratch -KeepGameDir |
    Where-Object { $_ -match '^(launch|OK|FAIL)' } | ForEach-Object { Write-Host ('          ' + $_) }

# 2. The folder the patcher wrote.
$throwaway = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-vp-launch'
$patched = @(Get-ChildItem -LiteralPath (Join-Path $throwaway 'shaderpacks') -Directory -Filter 'ComplementaryUnbound_* + EuphoriaPatches_*')
if ($patched.Count -ne 1) { throw "The patcher left $($patched.Count) patched folder(s) in the throwaway; expected one. Read $throwaway\logs\latest.log." }
$log = Join-Path $throwaway 'logs\latest.log'
if (-not (Select-String -Path $log -Pattern 'EuphoriaPatches was successfully installed' -Quiet)) {
    throw "The patcher did not report success - read $log"
}
Write-Host ("patched   {0}" -f $patched[0].Name)

# 3. The pack's edits, into the release.
& python $builder $ReleaseRoot $patched[0].FullName
if ($LASTEXITCODE -ne 0) { throw 'build_complementary.py failed' }
