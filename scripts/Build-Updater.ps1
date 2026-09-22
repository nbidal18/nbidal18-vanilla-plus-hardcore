<#
    Builds the two Prism pre-launch jars from client\*.java.

      nbidal18-packwiz-sync.jar      the supervisor. Small, stable, and what Prism actually runs.
                                     It promotes any staged .next.jar and then runs the updater.
      nbidal18-packwiz-updater.jar   the updater. Talks to the channel, drives packwiz-installer,
                                     shows real 0-100% progress, preserves player-owned files and
                                     enforces the manifest's property rules.

    Neither imports Minecraft or Fabric: they run before the game starts. That is why this builds
    with plain javac and no game jar on the classpath.

    Both are written to client\ and nowhere else. Build-PackwizSite stages the .next.jar copies
    into site\ before it refreshes the index, which is the only way they reach a player: packwiz
    downloads what the index lists, and the supervisor promotes what packwiz delivered. This script
    therefore has to run BEFORE Build-PackwizSite, not after it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$client = Join-Path $repo 'client'
$out = Join-Path $client 'java-build'

$jdk = Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-epsilon\bin'
$javac = Join-Path $jdk 'javac.exe'
$jar = Join-Path $jdk 'jar.exe'
foreach ($tool in $javac, $jar) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Missing $tool" }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

<#
    Rewrite a zip/jar with its entries in sorted order and every timestamp pinned, so identical
    input always produces identical bytes. Without this nothing downstream can be verified against
    a published copy: the archive differs on every build for reasons that have nothing to do with
    its contents.
#>
function Normalize-Archive([string] $path) {
    $epoch = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $items = [ordered]@{}
    $src = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        foreach ($e in ($src.Entries | Sort-Object FullName)) {
            $ms = New-Object IO.MemoryStream
            $s = $e.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
            $items[$e.FullName] = $ms.ToArray()
        }
    }
    finally { $src.Dispose() }

    Remove-Item -LiteralPath $path -Force
    $dst = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $items.Keys) {
            $entry = $dst.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $epoch
            $es = $entry.Open()
            try { $es.Write($items[$name], 0, $items[$name].Length) } finally { $es.Dispose() }
        }
    }
    finally { $dst.Dispose() }
}

if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

$sources = @(
    (Join-Path $client 'Nbidal18PackwizSync.java'),
    (Join-Path $client 'Nbidal18PackwizSupervisor.java')
)
& $javac -Xlint:all -Werror -d $out @sources
if ($LASTEXITCODE -ne 0) { throw "javac failed ($LASTEXITCODE)" }
Write-Host ("compiled  {0} classes" -f (Get-ChildItem -LiteralPath $out -Filter *.class).Count)

$builds = @(
    @{ jar = 'nbidal18-packwiz-sync.jar'; main = 'Nbidal18PackwizSupervisor' },
    @{ jar = 'nbidal18-packwiz-updater.jar'; main = 'Nbidal18PackwizSync' }
)
foreach ($b in $builds) {
    $target = Join-Path $client $b.jar
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    $classes = Get-ChildItem -LiteralPath $out -Filter ($b.main + '*.class') | ForEach-Object { $_.Name }
    if (-not $classes) { throw "No classes for $($b.main)" }
    Push-Location $out
    try {
        & $jar --create --file $target --main-class $b.main @classes
        if ($LASTEXITCODE -ne 0) { throw "jar failed for $($b.jar)" }
    }
    finally { Pop-Location }

    # `jar --create` stamps every entry with the current time, so an unchanged source produced a
    # different jar on each build - and those jars go inside nbidal18-client.zip, which made the
    # ZIP unreproducible too. Rewrite with sorted entries and a pinned timestamp.
    Normalize-Archive $target

    Write-Host ("built     {0,-34} {1,8:N0} B  ({2} classes)" -f $b.jar, (Get-Item -LiteralPath $target).Length, $classes.Count)
}

# Nothing is written to site\ here any more, and this script now runs FIRST.
#
# It used to copy each jar into site\ as both .jar and .next.jar, after Build-PackwizSite had
# already refreshed the index. The .next copies were therefore served but listed nowhere, so
# packwiz never downloaded them and no instance ever received a new update engine - the self-update
# path was dead from v1.0.0 to v1.0.2. Build-PackwizSite stages them before the refresh instead,
# which is what the 1.21.1 pack has always done.
#
# The live jars are not published at all: the client ZIP carries them for a first install, and
# indexing one would make packwiz overwrite the jar currently running the sync.
Write-Host "done      jars are in client\; Build-PackwizSite stages the .next copies"
