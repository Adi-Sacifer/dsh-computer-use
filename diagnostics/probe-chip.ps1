# One-shot diagnostic for the status chip: launch it, then ask Windows directly whether a real
# visible topmost window exists for that process and whether capture exclusion is in force.
param([int]$WaitSec = 5, [string]$Report = "$env:TEMP\chip-probe.txt", [string]$ExtraArgs = "", [switch]$SkipStatusWrite)

$ErrorActionPreference = 'Stop'
if (-not ('CpNat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CpNat {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint a);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    public static List<IntPtr> ForPid(uint want) {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == want) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool IsTopmost(IntPtr h) { return (GetWindowLong(h, -20) & 0x8) != 0; }
    public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }
}
'@
}

$lines = New-Object System.Collections.ArrayList
function Say($t) { [void]$lines.Add($t) }

$f = Join-Path $PSScriptRoot '..\scripts\cu-status.ps1'
$f = (Resolve-Path $f).Path
$st = Join-Path $env:TEMP 'cu-status.txt'
$log = Join-Path $env:TEMP 'cu-status.log'

# clean slate
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*cu-status.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
Remove-Item $log -Force -ErrorAction SilentlyContinue
Say ("log deleted before start: {0}" -f (-not (Test-Path $log)))

if (-not $SkipStatusWrite) {
    [System.IO.File]::WriteAllText($st,
        ("{0}|busy|3|uia find" -f [long]([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds),
        (New-Object System.Text.UTF8Encoding($false)))
}

$chipArgs = @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$f`"",
    '-StatusFile', "`"$st`"", '-IdleExitSec', '120')
if ($ExtraArgs) { $chipArgs += $ExtraArgs.Split(' ') }
$p = Start-Process -FilePath 'powershell' -WindowStyle Hidden -PassThru -ArgumentList $chipArgs
Say ("launched pid {0}" -f $p.Id)

Start-Sleep -Seconds $WaitSec
Say ("alive after {0}s: {1}" -f $WaitSec, (-not $p.HasExited))
if ($p.HasExited) { Say ("exit code: {0}" -f $p.ExitCode) }

$wins = [CpNat]::ForPid([uint32]$p.Id)
Say ("top-level windows for that pid: {0}" -f $wins.Count)
foreach ($h in $wins) {
    $r = New-Object CpNat+RECT
    [void][CpNat]::GetWindowRect($h, [ref]$r)
    $ex = [CpNat]::GetWindowLong($h, -20)
    # re-apply and read the result: SetWindowDisplayAffinity cannot be queried, only set
    $aff = [CpNat]::SetWindowDisplayAffinity($h, 0x11)
    Say ("  hwnd={0} class={1} visible={2} topmost={3} rect={4},{5} {6}x{7} ex=0x{8:X} affinityNow={9}" -f `
        $h.ToInt64(), [CpNat]::ClassOf($h), [CpNat]::IsWindowVisible($h), [CpNat]::IsTopmost($h), `
        $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top), $ex, $aff)
}

Say ("--- chip log ---")
if (Test-Path $log) { Say ([System.IO.File]::ReadAllText($log, [System.Text.Encoding]::UTF8).Trim()) } else { Say "(no log written)" }

[System.IO.File]::WriteAllText($Report, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
