# Does the chip actually resize to fit its message? That is exactly what failed before the
# UpdateLayout fix: the window kept the width it had at startup and long text was cut off.
# Measuring the window rect is deterministic, unlike trying to photograph a window that is
# deliberately excluded from screen capture.
param([string]$Report = "$env:TEMP\chip-size.txt")

$ErrorActionPreference = 'Stop'
if (-not ('CsNat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CsNat2 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    public static List<IntPtr> ForPid(uint want) {
        List<IntPtr> f = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == want) f.Add(h);
            return true;
        }, IntPtr.Zero);
        return f;
    }
}
'@
}

$lines = New-Object System.Collections.ArrayList
function Say($t) { [void]$lines.Add($t) }

$chip = Join-Path $PSScriptRoot '..\scripts\cu-status.ps1'
$chip = (Resolve-Path $chip).Path
$st = Join-Path $env:TEMP 'cu-status.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*cu-status.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 600

# long idle so it never closes mid-measurement
[System.IO.File]::WriteAllText($st, "1|busy|1|boot", $utf8)
$p = Start-Process -FilePath 'powershell' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$chip`"",
    '-StatusFile', "`"$st`"", '-IdleExitSec', '300')
Say ("chip pid {0}" -f $p.Id)
Start-Sleep -Seconds 3

function Measure-Chip([string]$label) {
    $hs = [CsNat2]::ForPid([uint32]$p.Id)
    $best = $null
    foreach ($h in $hs) {
        $r = New-Object CsNat2+RECT
        [void][CsNat2]::GetWindowRect($h, [ref]$r)
        $wd = $r.Right - $r.Left
        $ht = $r.Bottom - $r.Top
        if ($wd -gt 50 -and $ht -gt 10) {
            $ex = [CsNat2]::GetWindowLong($h, -20)
            if ($ex -band 0x08000000) { $best = @{ w = $wd; h = $ht; ex = $ex; hwnd = $h } }
        }
    }
    if ($best) {
        Say ("{0,-34} textlen={1,-3} -> window {2} x {3} (DIP)  layeredBit={4}" -f `
            $label, $script:lastLen, $best.w, $best.h, [bool]($best.ex -band 0x80000))
        return $best.w
    }
    Say ("{0,-34} textlen={1,-3} -> NOT FOUND" -f $label, $script:lastLen)
    return 0
}

$msgs = [System.IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'chip-msgs.txt'), [System.Text.Encoding]::UTF8) |
    Where-Object { $_.Trim() -ne '' }

$widths = @()
$i = 0
foreach ($m in $msgs) {
    $i++
    $script:lastLen = $m.Length
    [System.IO.File]::WriteAllText($st, ("{0}|busy|{1}|{2}" -f ([long]([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds), $i, $m), $utf8)
    Start-Sleep -Milliseconds 1200
    $widths += (Measure-Chip ("msg{0}" -f $i))
}

Say ""
$grew = ($widths[$widths.Count - 1] -gt $widths[0])
Say ("shortest={0}  longest={1}  grows-with-text={2}" -f $widths[0], $widths[$widths.Count - 1], $grew)
$monotonic = $true
for ($k = 1; $k -lt $widths.Count; $k++) { if ($widths[$k] -lt $widths[$k - 1] - 0) { } }
Say ("all widths: {0}" -f ($widths -join ', '))

[System.IO.File]::WriteAllText($Report, ($lines -join "`r`n"), $utf8)
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
