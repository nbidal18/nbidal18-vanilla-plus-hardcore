<#
    Runs nbidal18-voxyworldgen's window controller against modelled links and prints what a player
    on each would feel: the queueing delay a keep-alive would wait behind, and how much of the link
    the far-terrain stream used.

      scripts\Test-FlowController.ps1

    Why this exists: six releases of far-terrain pacing (v1.0.48 to v1.0.55) were tuned by
    shipping, watching one player's ping, and shipping again. Three of them made it worse. The
    control law is plain Java with no Minecraft in it, so it can be driven by a model in a second
    and read as a table before anybody plays. The model is crude - a FIFO link with bandwidth,
    base delay and jitter, a client that ingests at a fixed rate - and it is not a substitute for
    the play-test; it is what rules out a law that cannot work before the play-test is asked for.

    Fails when the 95th-percentile queueing delay stays above 200 ms on any link, or when the
    stream uses less than half of what the link and the client's ingest rate allow.

    Compiled with Prism's javac 25, like every other first-party mod. Never set JAVA_HOME for it.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
$release = Join-Path (Split-Path -Parent $repo) "$prefix$version"
$modRoot = Join-Path $release '5. modpack source\custom mods\nbidal18-voxyworldgen'
$javaBin = Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-epsilon\bin'
$javac = Join-Path $javaBin 'javac.exe'
$java = Join-Path $javaBin 'java.exe'
$controller = Join-Path $modRoot 'src\dev\nbidal18\voxyworldgen\Controller.java'
$simulation = Join-Path $modRoot 'test\ControllerSimulation.java'
foreach ($required in @($javac, $java, $controller, $simulation)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing input: $required" }
}

$out = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-flow-controller'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

& $javac -encoding UTF-8 -Xlint:all -Werror -d $out $controller $simulation
if ($LASTEXITCODE -ne 0) { throw 'javac failed for the controller simulation' }

& $java -cp $out ControllerSimulation
$exit = $LASTEXITCODE
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
if ($exit -ne 0) { throw "The controller simulation failed ($exit). Read the table above." }
