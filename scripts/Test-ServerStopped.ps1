<#
    Answers one question honestly: is the live server running?

      scripts\Test-ServerStopped.ps1              exit 0 if stopped, 1 if running
      scripts\Test-ServerStopped.ps1 -Quiet       same, no output

    **A TCP connect is not the answer.** The provider holds the port open with the server stopped,
    so a successful connection proves nothing, and a plain connect check has reported "down" for a
    server that was up. Only a Minecraft Server List Ping - handshake, then a status request, then
    an actual reply - distinguishes the two. Nothing else does.

    Deploy-LiveServer already refuses to write while the server answers, but it only pings when it
    is pointed at a live mount. Since `Y:` went away every deploy runs in rehearsal mode against a
    local mirror, so that ping never fires - and the push to the channel, which is what starts the
    lockout window, was never gated on anything at all. This is the check to run before both.
#>
[CmdletBinding()]
param(
    # Default: this repository's own server, from SERVER.txt. It used to be the Vanilla+ address
    # spelled out here, in both lines' copies of this script - so on the Vanilla++ line a run with no
    # arguments pinged the wrong machine and answered about the wrong server. Found 2026-10-06 asking
    # whether Vanilla++ was back up after the v1.0.22 deploy: it said RUNNING, and that was Vanilla+.
    # It failed safe that time. Reversed - Vanilla+ down, Vanilla++ up - it would have reported
    # 'stopped' about a live server, which is the one thing this script exists to prevent.
    # Filled in the body, not here: $PSScriptRoot is empty while param defaults are evaluated on
    # Windows PowerShell 5.1, which is how two other scripts came to throw and exit 0.
    [string] $ServerHost,
    [int] $Port,
    [int] $TimeoutSec = 8,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ServerHost -or -not $Port) {
    $serverFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'SERVER.txt'
    if (-not (Test-Path -LiteralPath $serverFile)) { throw "No SERVER.txt at $serverFile" }
    $fileHost, $filePort = ((Get-Content -LiteralPath $serverFile -Raw).Trim() -split ':', 2)
    if (-not $ServerHost) { $ServerHost = $fileHost }
    if (-not $Port) { $Port = [int] $filePort }
}

function Get-VarInt([int] $value) {
    $bytes = New-Object Collections.Generic.List[byte]
    do {
        $b = $value -band 0x7F
        $value = [int](([uint32] $value) -shr 7)
        if ($value -ne 0) { $b = $b -bor 0x80 }
        $bytes.Add([byte] $b)
    } while ($value -ne 0)
    # Comma on purpose: PowerShell unwraps a one-element array on return, and every varint here is
    # one byte, so without it the caller gets a scalar and AddRange throws.
    return , ([byte[]] $bytes.ToArray())
}

$client = New-Object Net.Sockets.TcpClient
$running = $false
$reason = 'no TCP connection'
try {
    $task = $client.ConnectAsync($ServerHost, $Port)
    if ($task.Wait($TimeoutSec * 1000) -and $client.Connected) {
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSec * 1000

        $hostBytes = [Text.Encoding]::UTF8.GetBytes($ServerHost)
        $payload = New-Object Collections.Generic.List[byte]
        $payload.AddRange((Get-VarInt 0))     # packet id: handshake
        $payload.AddRange((Get-VarInt 767))   # protocol; a server answers a status request whatever
        $payload.AddRange((Get-VarInt $hostBytes.Length))
        $payload.AddRange($hostBytes)
        $payload.Add([byte] (($Port -shr 8) -band 0xFF))
        $payload.Add([byte] ($Port -band 0xFF))
        $payload.AddRange((Get-VarInt 1))     # next state: status
        $frame = [byte[]] (@((Get-VarInt $payload.Count)) + $payload)
        $stream.Write($frame, 0, $frame.Length)

        $request = [byte[]] (@((Get-VarInt 1)) + (Get-VarInt 0))
        $stream.Write($request, 0, $request.Length)
        $stream.Flush()

        # One byte back is enough. Only a running Minecraft server answers a status request.
        if ($stream.ReadByte() -ge 0) { $running = $true; $reason = 'answered a Server List Ping' }
        else { $reason = 'port open, no status reply - the host is holding it' }
    }
}
catch { $reason = "no status reply ($($_.Exception.Message))" }
finally { $client.Close() }

if (-not $Quiet) {
    if ($running) { Write-Host ("RUNNING   {0}:{1} {2}" -f $ServerHost, $Port, $reason) }
    else { Write-Host ("STOPPED   {0}:{1} - {2}" -f $ServerHost, $Port, $reason) }
}
exit ([int] $running)
