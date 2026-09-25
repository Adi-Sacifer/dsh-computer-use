# Shared CU session lifetime. All child processes are windowless and inherit no handles.
$script:CuRuntimeDir = if ($env:DSH_CU_RUNTIME_DIR) { $env:DSH_CU_RUNTIME_DIR } else { Join-Path $env:TEMP 'dsh-cu-session' }
[void][IO.Directory]::CreateDirectory($script:CuRuntimeDir)
$script:CuSessionFile = Join-Path $script:CuRuntimeDir 'session.json'
$script:StatusPath = Join-Path $script:CuRuntimeDir 'status.txt'
$script:StatusPidPath = Join-Path $script:CuRuntimeDir 'status.pid'

function Get-CuSession {
    try {
        $session = [IO.File]::ReadAllText($script:CuSessionFile) | ConvertFrom-Json
        if (Test-Path -LiteralPath (Join-Path $script:CuRuntimeDir ('stop-' + $session.id))) { $session.active = $false }
        return $session
    } catch { return $null }
}
function Get-CuProcessRecord([int]$processId) {
    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($proc) { return @{ pid=$proc.Id; started=$proc.StartTime.ToUniversalTime().Ticks.ToString(); path=$proc.Path } }
    return $null
}
function Test-CuProcess($record) {
    if (-not $record -or $record.pid -le 0) { return $false }
    $proc = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    return [bool]($proc -and $proc.StartTime.ToUniversalTime().Ticks.ToString() -eq $record.started -and $proc.Path -eq $record.path)
}
function Write-CuSession($session) {
    $temp = $script:CuSessionFile + '.new'
    [IO.File]::WriteAllText($temp, ($session | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $script:CuSessionFile) { [IO.File]::Replace($temp, $script:CuSessionFile, [NullString]::Value) }
    else { [IO.File]::Move($temp, $script:CuSessionFile) }
}
function Invoke-CuSessionLock([scriptblock]$body) {
    # Same-user mutex prevents parallel first calls from stacking helpers.
    $mutex = [Threading.Mutex]::new($false, 'Local\DSH-CU-Session-v2')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'CU session is busy; retry after the current start/stop finishes.' }
        & $body
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Start-CuHidden([string]$scriptPath, [string]$arguments) {
    if (-not ('CuHiddenProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class CuHiddenProcess {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string reserved, desktop, title; public int x,y,cx,cy,xchars,ychars,fill,flags; public short show,reserved2; public IntPtr reservedPtr,input,output,error; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr process,thread; public int pid,tid; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static int Start(string exe, string args) {
        var si=new STARTUPINFO(); si.cb=Marshal.SizeOf(si); si.flags=1; si.show=0;
        PROCESS_INFORMATION pi;
        if(!CreateProcess(exe,new StringBuilder("\""+exe+"\" "+args),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,null,ref si,out pi)) throw new Win32Exception();
        CloseHandle(pi.thread); CloseHandle(pi.process); return pi.pid;
    }
}
'@
    }
    $exe = (Get-Process -Id $PID).Path
    return [CuHiddenProcess]::Start($exe, ('-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f $scriptPath, $arguments))
}
function Stop-CuSessionProcesses($session) {
    foreach ($record in @($session.fx, $session.chip)) {
        if (Test-CuProcess $record) { Stop-Process -Id $record.pid -Force -ErrorAction SilentlyContinue }
    }
}
function Stop-CuSession([switch]$OwnOnly) {
    Invoke-CuSessionLock {
        $session = Get-CuSession
        if (-not $session) { return }
        if ($OwnOnly -and $session.owner.pid -ne $PID) { return }
        if (-not $OwnOnly -and $SessionOwnerPid -gt 0 -and $session.active -and (Test-CuProcess $session.owner) -and $session.owner.pid -ne $SessionOwnerPid) {
            throw 'Another CU connection owns the desktop session; this connection cannot stop it.'
        }
        $session.active = $false
        Write-CuSession $session
        Stop-CuSessionProcesses $session
        Remove-Item -LiteralPath $script:StatusPidPath -Force -ErrorAction SilentlyContinue
    }
}
function Start-CuSession {
    Invoke-CuSessionLock {
        $session = Get-CuSession
        if ($session -and $session.active -and (Test-CuProcess $session.owner)) {
            if ($SessionOwnerPid -gt 0 -and $session.owner.pid -ne $SessionOwnerPid) { throw 'Another CU connection owns the desktop session. Stop that session before taking over.' }
        } else {
            if ($session) { Stop-CuSessionProcesses $session }
            $ownerId = $SessionOwnerPid
            if ($ownerId -le 0) {
                foreach ($row in [CuNat]::ListWindows($false)) {
                    $fields = $row -split '\|'
                    if ($fields[4] -match 'DeepSeek Harness') { $ownerId = [int]$fields[1]; break }
                }
            }
            if ($ownerId -le 0) { $ownerId = $PID }
            $session = [pscustomobject]@{ active=$true; id=[guid]::NewGuid().ToString(); owner=(Get-CuProcessRecord $ownerId); started=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); fx=$null; chip=$null }
            Remove-Item -LiteralPath $script:StatusPath -Force -ErrorAction SilentlyContinue
            Write-CuSession $session
        }
        try {
            $common = '-SessionFile "{0}" -SessionId "{1}"' -f $script:CuSessionFile, $session.id
            if (-not (Test-CuProcess $session.fx)) {
                $fxArgs = $common + (' -DurationSec {0}' -f $DurationSec)
                if ($DimPct -ge 0) { $fxArgs += ' -Dim ' + ($DimPct / 100.0).ToString([Globalization.CultureInfo]::InvariantCulture) }
                if ($DimAfter -ge 0) { $fxArgs += (' -DimAfterSec {0}' -f $DimAfter) }
                if ($Action -in @('start','fxon') -and $Text) {
                    $headline = Join-Path $script:CuRuntimeDir 'headline.txt'
                    [IO.File]::WriteAllText($headline, $Text, [Text.UTF8Encoding]::new($false))
                    $fxArgs += (' -TextFile "{0}"' -f $headline)
                }
                $session.fx = Get-CuProcessRecord (Start-CuHidden (Join-Path $PSScriptRoot 'fx.ps1') $fxArgs)
                Write-CuSession $session
            }
            if (-not (Test-CuProcess $session.chip)) {
                $chipArgs = $common + (' -StatusFile "{0}"' -f $script:StatusPath)
                $session.chip = Get-CuProcessRecord (Start-CuHidden (Join-Path $PSScriptRoot 'cu-status.ps1') $chipArgs)
                Write-CuSession $session
            }
        } catch {
            $session.active = $false; Write-CuSession $session; Stop-CuSessionProcesses $session; throw
        }
    }
}

# Called only by the GUI helpers. A replaced session or dead/reused owner PID ends both.
function Test-CuSessionOwner([string]$file, [string]$sessionId) {
    try {
        $current = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        return [bool]($current.active -and $current.id -eq $sessionId -and -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $file) ('stop-' + $sessionId))) -and (Test-CuProcess $current.owner))
    } catch { return $false }
}
