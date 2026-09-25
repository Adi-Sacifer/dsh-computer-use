# Probe v2: recursive accessibility wake for Chromium/Electron windows.
# Finds every descendant HWND, pokes WM_GETOBJECT/OBJID_CLIENT at each, then reports which
# HWND actually yields a rich UIA tree. Answers: "what do we have to poke to get real rects?"
param(
    [long]$Hwnd = 0,
    [int]$WaitMs = 3000,
    [int]$MaxDepth = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not ('A11yNat2' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class A11yNat2
{
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    public delegate bool EnumProc(IntPtr h, IntPtr lp);
    public const uint WM_GETOBJECT = 0x003D;
    public static readonly IntPtr OBJID_CLIENT = new IntPtr(unchecked((int)0xFFFFFFFC));
    public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }
    public static string TextOf(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowTextW(h, sb, sb.Capacity); return sb.ToString(); }
    public static List<IntPtr> Children(IntPtr parent)
    {
        List<IntPtr> kids = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr lp) { kids.Add(h); return true; }, IntPtr.Zero);
        return kids;
    }
    public static bool Poke(IntPtr h)
    {
        IntPtr res;
        SendMessageTimeout(h, WM_GETOBJECT, IntPtr.Zero, OBJID_CLIENT, 0x0002, 4000, out res);
        return res != IntPtr.Zero;
    }
}
'@
}

function Get-Stats($h) {
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($h) } catch { return $null }
    if (-not $root) { return $null }
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $named = 0; $rect = 0; $total = 0
    foreach ($el in $all) {
        $total++
        try {
            $c = $el.Current
            if (-not [string]::IsNullOrWhiteSpace($c.Name)) { $named++ }
            $r = $c.BoundingRectangle
            if ($r.Width -gt 0 -and $r.Height -gt 0) { $rect++ }
        } catch { }
    }
    return [pscustomobject]@{ total = $total; named = $named; rect = $rect }
}

# collect descendants breadth-first up to MaxDepth
$all = New-Object System.Collections.ArrayList
$frontier = @([IntPtr]$Hwnd)
$depth = 0
$level = @{ ([IntPtr]$Hwnd) = 0 }
while ($frontier.Count -gt 0 -and $depth -lt $MaxDepth) {
    $next = @()
    foreach ($f in $frontier) {
        foreach ($k in [A11yNat2]::Children($f)) {
            if (-not $all.Contains($k)) { [void]$all.Add($k); $next += $k }
        }
    }
    $frontier = $next
    $depth++
}
Write-Output ("target {0} : [{1}] {2}" -f ([IntPtr]$Hwnd).ToInt64(), [A11yNat2]::ClassOf([IntPtr]$Hwnd), [A11yNat2]::TextOf([IntPtr]$Hwnd))
Write-Output ("descendant hwnds found: {0}" -f $all.Count)
foreach ($k in $all) { Write-Output ("  {0,-10} [{1}] {2}" -f $k.ToInt64(), [A11yNat2]::ClassOf($k), [A11yNat2]::TextOf($k)) }

Write-Output "--- before ---"
$targets = @([IntPtr]$Hwnd) + @($all)
foreach ($t in $targets) {
    $s = Get-Stats $t
    if ($s) { Write-Output ("  {0,-10} total={1,-5} named={2,-5} rect={3}" -f $t.ToInt64(), $s.total, $s.named, $s.rect) }
}

Write-Output "--- poking every hwnd ---"
foreach ($t in $targets) { $ok = [A11yNat2]::Poke($t); Write-Output ("  poke {0,-10} answered={1}" -f $t.ToInt64(), $ok) }

Start-Sleep -Milliseconds $WaitMs

Write-Output "--- after (single sweep) ---"
foreach ($t in $targets) {
    $s = Get-Stats $t
    if ($s) { Write-Output ("  {0,-10} total={1,-5} named={2,-5} rect={3}" -f $t.ToInt64(), $s.total, $s.named, $s.rect) }
}

# A second sweep catches trees that only build after the engine noticed a real AT client.
foreach ($t in $targets) { [void][A11yNat2]::Poke($t) }
Start-Sleep -Milliseconds 1500
Write-Output "--- after (second sweep) ---"
foreach ($t in $targets) {
    $s = Get-Stats $t
    if ($s) { Write-Output ("  {0,-10} total={1,-5} named={2,-5} rect={3}" -f $t.ToInt64(), $s.total, $s.named, $s.rect) }
}
