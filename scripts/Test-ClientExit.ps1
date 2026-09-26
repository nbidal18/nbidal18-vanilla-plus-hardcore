<#
    Proves the client can QUIT. Starts a throwaway client inside a world (or onto a server), closes
    its window the way a player does, and fails if the process is still alive afterwards - dumping
    every thread first, while the hang is fresh, so the cause is named rather than guessed.

      scripts\Test-ClientExit.ps1 -InstanceName <prism instance> -World <saves> -QuickPlay <level>
      scripts\Test-ClientExit.ps1 -InstanceName <prism instance> -QuickPlayServer <host:port>

    Why this exists, 2026-09-24: v1.0.0 to v1.0.2 of the hardcore pack left a windowless JVM behind
    on every quit from a world. Test-ClientLaunch.ps1 cannot see that by design - it proves the
    client STARTS and reads the log for known faults, and a quit hang produces no log line at all.
    Two bugs were found with this probe's scratch version and fixed in v1.0.3 (nbidal18-soundsbegone
    1.1.0, nbidal18-ixeris 1.0.0); the account is in the ledger, *The client that would not exit*.

    What a failure gives you: two thread dumps in %TEMP% - Java frames, then mixed with native
    frames - taken with the serviceability agent (`jhsdb jstack`) from the SAME runtime the client
    ran on. jhsdb attaches from outside, so it works when the JVM will no longer answer `jcmd`,
    which is exactly the state a wedged shutdown is in. The three hottest threads are printed twice,
    five seconds apart, so a spinning thread shows as one whose CPU time keeps climbing.

    The launch is Test-ClientLaunch.ps1 -Hold, so everything it stages and checks applies here too:
    the shipped client content, the server's Vanilla Refresh settings for a hosted world, music off.
    Nothing here touches a real instance - the throwaway is Test-ClientLaunch's, under %TEMP%.
#>
[CmdletBinding()]
param(
    # The Prism instance whose launcher metadata gives the classpath and the runtime. Read only.
    [Parameter(Mandatory)] [string] $InstanceName,
    # A saves folder to host, with the level to enter - the same pair Test-ClientLaunch takes.
    [string] $World,
    [string] $QuickPlay,
    # Or a server to join instead. The two are exclusive.
    [string] $QuickPlayServer,
    # How long a healthy quit may take. v1.0.3 quits from a world in seconds; the hang never quit.
    [int] $WaitSeconds = 45,
    # Names the dump files, so two probes in one session do not overwrite each other.
    [string] $Label = 'exit'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $QuickPlay -and -not $QuickPlayServer) { throw 'Give -World with -QuickPlay, or -QuickPlayServer: a quit from the title screen never hung.' }
if ($QuickPlay -and -not $World) { throw '-QuickPlay needs -World: the saves folder holding that level.' }
if ($QuickPlay -and $QuickPlayServer) { throw '-QuickPlay and -QuickPlayServer are exclusive.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-vp-launch'
$launch = Join-Path $PSScriptRoot 'Test-ClientLaunch.ps1'

# The staging folder is Test-ClientLaunch's, and it wipes it on start. A client still holding it -
# an earlier -Hold run the owner is looking at - would make that wipe fail halfway, or worse, close
# something the owner is using. Refuse rather than guess whose it is.
$already = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" |
    Where-Object { $_.CommandLine -like "*$testRoot*" })
if ($already.Count) {
    throw ("A throwaway client is already running (pid {0}). Close it first; this probe will not " +
        "close a client it did not start.") -f ($already[0].ProcessId)
}

# 1. Start it, inside the world or on the server, and let Test-ClientLaunch prove it got there.
$launchArgs = @{ InstanceName = $InstanceName; Hold = $true; KeepGameDir = $true }
if ($QuickPlayServer) { $launchArgs.QuickPlayServer = $QuickPlayServer }
else { $launchArgs.World = $World; $launchArgs.QuickPlay = $QuickPlay }
& $launch @launchArgs

$p = Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" |
    Where-Object { $_.CommandLine -like "*$testRoot*" } | Select-Object -First 1
if (-not $p) { throw 'Test-ClientLaunch returned but no throwaway client is running.' }
$proc = Get-Process -Id $p.ProcessId
$log = Join-Path $testRoot 'logs\latest.log'

# 2. Close the GAME window like a player: WM_CLOSE to it, nothing else. No synthetic input.
#
# Not Process.CloseMainWindow(). The throwaway is started by java.exe with a console, and .NET's
# "main window" of that process is the console, not the game. Closing the console kills the JVM on
# the spot, which looked like a clean two-second quit and proved nothing - found 2026-09-26 when
# Litematica's settings, which it writes on a normal quit, never appeared. The game window is the
# one of class GLFW30 belonging to the process.
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class ExitWin {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  public static IntPtr Find(uint pid, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, x) => { uint w; GetWindowThreadProcessId(h, out w); if (w != pid) return true;
      var sb = new StringBuilder(256); GetClassName(h, sb, 256);
      if (sb.ToString() == cls) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static string Title(IntPtr h) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
}
'@
$gameWindow = [ExitWin]::Find([uint32] $proc.Id, 'GLFW30')
if ($gameWindow -eq [IntPtr]::Zero) { throw 'The client has no game window (class GLFW30) to close.' }
Write-Host ("client    pid {0}, game window '{1}'" -f $proc.Id, [ExitWin]::Title($gameWindow))
if (-not [ExitWin]::PostMessage($gameWindow, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'WM_CLOSE could not be posted to the game window.' }
$closedAt = Get-Date
Write-Host ("closed    window at {0}; waiting up to {1} s for the process to end" -f $closedAt.ToString('HH:mm:ss'), $WaitSeconds)

# 3. The one wait this probe owns. It ends with a verdict, never with a peek.
if ($proc.WaitForExit($WaitSeconds * 1000)) {
    Write-Host ("exited    {0:N1} s after the window closed" -f ((Get-Date) - $closedAt).TotalSeconds)
    Write-Host ''
    Write-Host ('OK        the client quit cleanly from {0}' -f $(if ($QuickPlayServer) { $QuickPlayServer } else { "world '$QuickPlay'" }))
    exit 0
}

# 4. Still alive: name the cause before killing it.
$proc.Refresh()
$hottest = { param($pr) ($pr.Threads | Sort-Object TotalProcessorTime -Descending | Select-Object -First 3 |
    ForEach-Object { '{0}={1:N1}s' -f $_.Id, $_.TotalProcessorTime.TotalSeconds }) -join ' ' }
Write-Host ("ALIVE     {0} threads, window '{1}'; hottest {2}" -f $proc.Threads.Count, $proc.MainWindowTitle, (& $hottest $proc))
Start-Sleep -Seconds 5
$proc.Refresh()
Write-Host ("          5 s later: {0}  (a climbing figure is a spinning thread)" -f (& $hottest $proc))

# jhsdb from the runtime the client is actually running on - never a hardcoded JDK.
$jhsdb = Join-Path (Split-Path -Parent $p.ExecutablePath) 'jhsdb.exe'
if (-not (Test-Path -LiteralPath $jhsdb)) { throw "No jhsdb.exe beside the client's java ($($p.ExecutablePath)); cannot dump. Process $($proc.Id) left running for a manual dump." }
$dumpJava = Join-Path ([IO.Path]::GetTempPath()) ("exit-hang-$Label-java.txt")
$dumpMixed = Join-Path ([IO.Path]::GetTempPath()) ("exit-hang-$Label-mixed.txt")
& $jhsdb jstack --pid $proc.Id 2>&1 | Out-File -LiteralPath $dumpJava -Encoding utf8
& $jhsdb jstack --mixed --pid $proc.Id 2>&1 | Out-File -LiteralPath $dumpMixed -Encoding utf8
Write-Host ("dumped    {0} ({1:N0} bytes)" -f $dumpJava, (Get-Item -LiteralPath $dumpJava).Length)
Write-Host ("dumped    {0} ({1:N0} bytes)" -f $dumpMixed, (Get-Item -LiteralPath $dumpMixed).Length)
if (Test-Path -LiteralPath $log) {
    Write-Host 'log tail:'
    Get-Content -LiteralPath $log -Tail 5 | ForEach-Object { '   ' + $_.Substring(0, [Math]::Min(140, $_.Length)) }
}
$proc.Kill(); $proc.WaitForExit(15000) | Out-Null
throw ("The client did not exit within {0} s of its window closing. Killed. Read the mixed dump first: " +
    "the thread named `Render thread` or `main` says where the shutdown is stuck.") -f $WaitSeconds
