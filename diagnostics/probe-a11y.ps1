# Probe: does a Chromium/Electron window expose a usable UIA tree, and can we wake it?
# Read-only w.r.t. the app: we only ask for accessibility objects and count nodes.
param(
    [long]$Hwnd = 0,
    [string]$Title = '',
    [int]$WaitMs = 2500
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

if (-not ('A11yNat' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class A11yNat
{
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    public delegate bool EnumProc(IntPtr h, IntPtr lp);

    public const uint WM_GETOBJECT = 0x003D;
    public static readonly IntPtr OBJID_CLIENT = new IntPtr(unchecked((int)0xFFFFFFFC));
    public const uint SPI_GETSCREENREADER = 0x0046;
    public const uint SPI_SETSCREENREADER = 0x0047;
    public const uint SPIF_SENDCHANGE = 0x02;

    public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }
    public static string TextOf(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowTextW(h, sb, sb.Capacity); return sb.ToString(); }

    public static List<IntPtr> Children(IntPtr parent)
    {
        List<IntPtr> kids = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr lp) { kids.Add(h); return true; }, IntPtr.Zero);
        return kids;
    }

    // Ask the window for its client accessibility object. This is the same poke a screen
    // reader makes, and it is what flips Chromium's accessibility engine on.
    public static bool PokeAccessible(IntPtr h)
    {
        IntPtr res;
        SendMessageTimeout(h, WM_GETOBJECT, IntPtr.Zero, OBJID_CLIENT, 0x0002, 3000, out res);
        return res != IntPtr.Zero;
    }

}
'@
}

function Count-Nodes($root, [int]$max = 4000) {
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $named = 0; $total = 0; $withRect = 0
    $types = @{}
    foreach ($el in $all) {
        $total++
        if ($total -gt $max) { break }
        try {
            $c = $el.Current
            if (-not [string]::IsNullOrWhiteSpace($c.Name)) { $named++ }
            $r = $c.BoundingRectangle
            if ($r.Width -gt 0 -and $r.Height -gt 0) { $withRect++ }
            $ct = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''
            if ($types.ContainsKey($ct)) { $types[$ct]++ } else { $types[$ct] = 1 }
        } catch { }
    }
    return [pscustomobject]@{ total = $total; named = $named; withRect = $withRect; types = $types }
}

$h = [IntPtr]$Hwnd
if ($Hwnd -le 0) {
    $procs = Get-Process | Where-Object { $_.MainWindowTitle -like "*$Title*" } | Select-Object -First 1
    if (-not $procs) { throw "no window matching '$Title'" }
    $h = $procs.MainWindowHandle
}
Write-Output ("target hwnd {0} : [{1}] {2}" -f $h.ToInt64(), [A11yNat]::ClassOf($h), [A11yNat]::TextOf($h))

$kids = [A11yNat]::Children($h)
Write-Output ("--- child windows ({0}) ---" -f $kids.Count)
foreach ($k in $kids) {
    Write-Output ("  {0,-10} class={1,-40} text={2}" -f $k.ToInt64(), [A11yNat]::ClassOf($k), [A11yNat]::TextOf($k))
}

$root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$before = Count-Nodes $root
Write-Output ("BEFORE : total={0} named={1} withRect={2}" -f $before.total, $before.named, $before.withRect)

# Poke every child (the render widget host lives among them) with WM_GETOBJECT.
$poked = 0
foreach ($k in $kids) { if ([A11yNat]::PokeAccessible($k)) { $poked++ } }
[void][A11yNat]::PokeAccessible($h)
Write-Output ("poked WM_GETOBJECT/OBJID_CLIENT: {0} children answered" -f $poked)

Start-Sleep -Milliseconds $WaitMs

$root2 = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$after = Count-Nodes $root2
Write-Output ("AFTER  : total={0} named={1} withRect={2}" -f $after.total, $after.named, $after.withRect)

Write-Output "--- control types after ---"
foreach ($kv in ($after.types.GetEnumerator() | Sort-Object Value -Descending)) { Write-Output ("  {0,-22} {1}" -f $kv.Key, $kv.Value) }

Write-Output "--- first 25 named nodes with a rect ---"
$i = 0
foreach ($el in $root2.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    try {
        $c = $el.Current
        if ([string]::IsNullOrWhiteSpace($c.Name)) { continue }
        $r = $c.BoundingRectangle
        if ($r.Width -le 0) { continue }
        $i++
        Write-Output ("  {0,-14} | {1,-30} | {2},{3} {4}x{5}" -f ($c.ControlType.ProgrammaticName -replace 'ControlType\.',''), $c.Name, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
        if ($i -ge 25) { break }
    } catch { }
}
Write-Output ("named+rect shown: {0}" -f $i)
