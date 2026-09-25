# Probe v3: which wake strategy actually turns on accessibility for a stubborn Chromium app?
# Strategies tried in order, measuring the UIA node count after each:
#   1. WM_GETOBJECT / OBJID_CLIENT           (worked for DSH)
#   2. WM_GETOBJECT / UiaRootObjectId (-25)  (the documented UIA entry point)
#   3. AccessibleObjectFromWindow(IID_IAccessible)  (what a legacy screen reader does)
#   4. SPI_SETSCREENREADER = TRUE            (system "AT present" flag)
# Nothing here writes to the target app; it only asks for accessibility objects.
param(
    [long]$Hwnd = 0,
    [int]$WaitMs = 2000
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not ('A11yNat3' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class A11yNat3
{
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref int pvParam, uint fWinIni);
    [DllImport("oleacc.dll")] public static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint dwId, ref Guid riid, [In, Out, MarshalAs(UnmanagedType.IUnknown)] ref object ppvObject);

    public delegate bool EnumProc(IntPtr h, IntPtr lp);

    public const uint WM_GETOBJECT = 0x003D;
    public static readonly IntPtr OBJID_CLIENT = new IntPtr(unchecked((int)0xFFFFFFFC));
    public static readonly IntPtr UIA_ROOT_OBJECT_ID = new IntPtr(-25);
    public const uint SPI_GETSCREENREADER = 0x0046;
    public const uint SPI_SETSCREENREADER = 0x0047;
    public const uint SPIF_UPDATEINIFILE = 0x01;
    public const uint SPIF_SENDCHANGE = 0x02;

    public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }
    public static string TextOf(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowTextW(h, sb, sb.Capacity); return sb.ToString(); }

    public static List<IntPtr> Children(IntPtr parent)
    {
        List<IntPtr> kids = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr lp) { kids.Add(h); return true; }, IntPtr.Zero);
        return kids;
    }

    public static bool PokeClient(IntPtr h)
    {
        IntPtr res;
        SendMessageTimeout(h, WM_GETOBJECT, IntPtr.Zero, OBJID_CLIENT, 0x0002, 4000, out res);
        return res != IntPtr.Zero;
    }

    public static bool PokeUia(IntPtr h)
    {
        IntPtr res;
        SendMessageTimeout(h, WM_GETOBJECT, IntPtr.Zero, UIA_ROOT_OBJECT_ID, 0x0002, 4000, out res);
        return res != IntPtr.Zero;
    }

    public static bool PokeAccessible(IntPtr h)
    {
        Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71"); // IID_IAccessible
        object acc = null;
        int hr = AccessibleObjectFromWindow(h, 0xFFFFFFFC, ref iid, ref acc);
        return hr == 0 && acc != null;
    }

    public static bool GetScreenReader()
    {
        int v = 0;
        SystemParametersInfo(SPI_GETSCREENREADER, 0, ref v, 0);
        return v != 0;
    }

    public static bool SetScreenReader(bool on)
    {
        int v = on ? 1 : 0;
        return SystemParametersInfo(SPI_SETSCREENREADER, (uint)v, ref v, SPIF_SENDCHANGE);
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

function Report($label, $targets) {
    foreach ($t in $targets) {
        $s = Get-Stats $t
        if ($s) { Write-Output ("  {0,-34} {1,-10} total={2,-5} named={3,-5} rect={4}" -f $label, $t.ToInt64(), $s.total, $s.named, $s.rect) }
    }
}

$h = [IntPtr]$Hwnd
$targets = @($h) + @([A11yNat3]::Children($h))
Write-Output ("target {0} : [{1}] {2}" -f $h.ToInt64(), [A11yNat3]::ClassOf($h), [A11yNat3]::TextOf($h))
foreach ($t in $targets) { Write-Output ("  hwnd {0,-10} [{1}] {2}" -f $t.ToInt64(), [A11yNat3]::ClassOf($t), [A11yNat3]::TextOf($t)) }
Write-Output ("screenReaderFlag(SPI_GETSCREENREADER) = {0}" -f [A11yNat3]::GetScreenReader())

Write-Output "--- 0. baseline ---"
Report 'baseline' $targets

Write-Output "--- 1. WM_GETOBJECT OBJID_CLIENT ---"
foreach ($t in $targets) { [void][A11yNat3]::PokeClient($t) }
Start-Sleep -Milliseconds $WaitMs
Report 'after OBJID_CLIENT' $targets

Write-Output "--- 2. WM_GETOBJECT UiaRootObjectId(-25) ---"
foreach ($t in $targets) { [void][A11yNat3]::PokeUia($t) }
Start-Sleep -Milliseconds $WaitMs
Report 'after UiaRootObjectId' $targets

Write-Output "--- 3. AccessibleObjectFromWindow(IID_IAccessible) ---"
foreach ($t in $targets) { $ok = [A11yNat3]::PokeAccessible($t); Write-Output ("  IAccessible from {0} -> {1}" -f $t.ToInt64(), $ok) }
Start-Sleep -Milliseconds $WaitMs
Report 'after IAccessible' $targets

Write-Output "--- 4. SPI_SETSCREENREADER TRUE ---"
$set = [A11yNat3]::SetScreenReader($true)
Write-Output ("  SetScreenReader -> {0}, now flag={1}" -f $set, [A11yNat3]::GetScreenReader())
Start-Sleep -Milliseconds ($WaitMs + 2000)
Report 'after screenReader flag' $targets
foreach ($t in $targets) { [void][A11yNat3]::PokeClient($t) }
Start-Sleep -Milliseconds $WaitMs
Report 'flag + OBJID_CLIENT' $targets

Write-Output "--- 5. leaving the flag in place for the caller to decide ---"
Write-Output ("  screenReaderFlag now = {0}  (revert with: SystemParametersInfo SPI_SETSCREENREADER 0)" -f [A11yNat3]::GetScreenReader())
