#!/usr/bin/env powershell
<#
  cu.ps1 - DSH computer-use toolkit (Windows desktop control).
  NOTE: ASCII-only on purpose. Windows PowerShell 5.1 reads BOM-less UTF-8 as the
  ANSI codepage, which corrupts non-ASCII source and breaks parsing.

  Actions:
    info                    screen metrics, cursor, foreground window
    shot                    screenshot -> PNG (full screen / -X -Y -W -H / -Title "win")
    cursor                  print cursor position
    move     -X -Y
    click    [-X -Y] [-Button left|right|middle] [-Double] [-Count n]
    drag     -X1 -Y1 -X2 -Y2
    scroll   [-Amount n] [-X -Y]     negative = down
    type     -Text "..."             Unicode-safe (CJK / emoji)
    paste    -Text "..."             clipboard + Ctrl+V, for long text
    key      -Keys "ctrl+s" | "enter" | "alt+tab" | "f5"
    windows  [-All]
    focus    -Title "..." | -Hwnd n
    clip     [-Text "..."]           no -Text = read clipboard
    uia      -Mode tree|find|click|settext|focus [-Name "..."] [-Text "..."] [-Depth n] [-Title "win"]
    wake     [-Hwnd n | -Title "win"]   turn a Chromium/Electron window's a11y tree on and report it
    sleep    -DelayMs n
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('info', 'shot', 'cursor', 'move', 'click', 'drag', 'scroll', 'type', 'paste', 'key', 'windows', 'focus', 'clip', 'wtext', 'uia', 'wake', 'status', 'show', 'place', 'sleep', 'fxon', 'fxoff', 'fxstatus')]
    [string]$Action,

    [int]$X, [int]$Y,
    [int]$X1, [int]$Y1, [int]$X2, [int]$Y2,
    [int]$W, [int]$H,

    [ValidateSet('left', 'right', 'middle')]
    [string]$Button = 'left',

    [switch]$Double,
    [int]$Amount = -3,
    [int]$Count = 1,
    [string]$Text,
    [string]$Keys,
    [string]$Path,
    [string]$Title,
    [string]$Name,

    # Input guard for the actions that inject synthetic input (click/key/type/paste/scroll/drag).
    # It exists for the failure the SKILL documents: SetForegroundWindow can fail silently, so
    # `focus` reports success while the window is NOT foreground - and then every keystroke lands
    # in whatever window really is, while each action still reports success. With
    # -Expect "<title substring>" an input action re-checks the foreground window immediately
    # before injecting and REFUSES (non-zero, naming the window that would have received the
    # input) instead of injecting blind. Empty default = no check, old behaviour unchanged.
    [string]$Expect = '',
    [string]$Mode = 'tree',
    [int]$Depth = 6,
    [long]$Hwnd = 0,
    [switch]$All,
    [switch]$Json,
    [switch]$KeepFx,
    [int]$DimPct = -1,
    [int]$DimAfter = -1,
    [int]$WatchPid = -1,
    [int]$Grid = 0,
    # Overlay lifetime. The effect is meant to mark a WHOLE takeover, so the default is a
    # day: it ends when fxoff is called, when the user's harness process disappears (the
    # watchdog), or via the kill switch - not by the clock. The value remains a backstop.
    [int]$DurationSec = 86400,
    [int]$DelayMs = 25,

    # Accessibility wake-up. Chromium/Electron/web apps report an empty UIA tree until an
    # assistive-technology client asks for an accessibility object, so every `uia` action
    # wakes the target first unless -NoWake is given. -WakeMs bounds the wait for the tree
    # to build; the call returns as soon as it stops growing.
    [switch]$NoWake,
    [int]$WakeMs = 2500,

    # Which match to act on when a name matches several controls (1-based), and whether the
    # name must match exactly. Both exist because "-like *name*" used to silently act on the
    # first hit, which is often an off-screen or hidden duplicate.
    [int]$Index = 1,
    [switch]$Exact,

    # Activity chip (cu-status.ps1). Every action announces itself so the user can watch
    # computer-use progress without raising the harness window and fighting the pointer.
    # -NoChip suppresses the chip for one call.
    [switch]$NoChip,
    [ValidateSet('busy', 'note', 'ok', 'err', 'done')]
    [string]$State = 'note'
)

# MAINTENANCE HAZARD, learned the hard way - read before adding a variable below.
# PowerShell variable names are case-insensitive, so every parameter above also exists, with
# its declared type, as a variable in the script scope. Assigning to a name that collides
# silently CONVERTS the value to the parameter's type, or throws a confusing
# "Cannot convert ... to type System.Int32" MetadataError naming this script rather than the
# offending line. Two real bugs came from exactly this:
#   * $w = <object>  hit [int]$W, and threw;
#   * $h = <hwnd>    hit [int]$H, so `place` passed the window handle as the height.
# So use distinct locals at script scope ($win, $report, $targetHwnd, ...), and never $h/$w/
# $x/$y/$count/$text/$name/$mode/$title/$path/$grid.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# WHICH HOST ARE WE? -- this toolkit now runs under Windows PowerShell 5.1 AND PowerShell 7,
# and the detached GUI helpers (the activity chip, the fx overlay) must be started by the SAME
# host that is running this file. Hardcoding 'powershell' was correct only while 5.1 was the
# only host: once pwsh 7 is installed the STORE ALIAS C:\...\WindowsApps\powershell.exe (and
# 'pwsh') resolves to pwsh, so the child comes up as pwsh.exe while the duplicate-chip guard
# below still filtered on Name='powershell.exe' -- the guard would never see it and every
# action would stack another pill on the same spot. Derive the name from $PSHOME instead, so
# the launcher and the guard can never disagree again.
$script:HostExe = 'powershell'
if (Test-Path (Join-Path $PSHOME 'pwsh.exe')) { $script:HostExe = 'pwsh' }
$script:HostNames = @('powershell.exe', 'pwsh.exe', 'pwsh-preview.exe')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('CuNat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class CuNat
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001, KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    public delegate bool EnumProc(IntPtr h, IntPtr lp);

    // --- Accessibility wake-up -------------------------------------------------------
    // Chromium/Electron (DSH itself, the Codex/ChatGPT desktop app, Steam, any web page in
    // Chrome or Edge) keeps its accessibility engine OFF until a real assistive-technology
    // client asks for an accessibility object. Until then UIA reports a near-empty tree, so
    // the only way to aim was to eyeball a downscaled screenshot - which is exactly why
    // clicks kept landing on the wrong button. Asking for WM_GETOBJECT/OBJID_CLIENT is what
    // a screen reader does on startup; it costs one message and turns the tree on for the
    // whole process. Measured here: the harness window went from 13 nodes / 4 named to
    // 158 nodes / 140 named, every one with a real rectangle.
    public const uint WM_GETOBJECT = 0x003D;
    public const uint SMTO_ABORTIFHUNG = 0x0002;
    public static readonly IntPtr OBJID_CLIENT = new IntPtr(unchecked((int)0xFFFFFFFC));
    public static readonly IntPtr UIA_ROOT_OBJECT_ID = new IntPtr(-25);

    public static bool PokeAccessible(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        IntPtr a, b;
        SendMessageTimeout(h, WM_GETOBJECT, IntPtr.Zero, OBJID_CLIENT, SMTO_ABORTIFHUNG, 3000, out a);
        SendMessageTimeout(h, WM_GETOBJECT, IntPtr.Zero, UIA_ROOT_OBJECT_ID, SMTO_ABORTIFHUNG, 3000, out b);
        return a != IntPtr.Zero || b != IntPtr.Zero;
    }

    public static List<IntPtr> ChildWindows(IntPtr parent)
    {
        List<IntPtr> kids = new List<IntPtr>();
        if (parent == IntPtr.Zero) return kids;
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr lp) { kids.Add(h); return true; }, IntPtr.Zero);
        return kids;
    }

    public static string ClassOf(IntPtr h)
    {
        if (h == IntPtr.Zero) return "";
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // Which top-level window actually owns a screen point. Reported after every click so a
    // miss is visible immediately instead of looking like "the button did nothing".
    public static IntPtr TopLevelAt(int x, int y)
    {
        POINT p; p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return IntPtr.Zero;
        IntPtr top = GetAncestor(h, 2); // GA_ROOT
        return top == IntPtr.Zero ? h : top;
    }

    public static int InputSize() { return Marshal.SizeOf(typeof(INPUT)); }

    // These return SendInput's accepted-event count. It is the only way to tell "the click was
    // delivered" from "the click was swallowed" - e.g. UIPI silently drops input aimed at a
    // higher-integrity (elevated) window, and the return value is 0 with no exception.
    public static uint MouseEvent(uint flags, int data)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_MOUSE;
        a[0].U.mi.dwFlags = flags;
        a[0].U.mi.mouseData = (uint)data;
        return SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint KeyEvent(ushort vk, bool up, bool extended)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_KEYBOARD;
        a[0].U.ki.wVk = vk;
        a[0].U.ki.wScan = 0;
        a[0].U.ki.dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0);
        return SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint UnicodeChar(char c, bool up)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_KEYBOARD;
        a[0].U.ki.wVk = 0;
        a[0].U.ki.wScan = c;
        a[0].U.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
        return SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string WindowText(IntPtr h)
    {
        int n = GetWindowTextLengthW(h);
        if (n <= 0) return "";
        StringBuilder sb = new StringBuilder(n + 2);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static List<string> ListWindows(bool visibleOnly)
    {
        List<string> outList = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            if (visibleOnly && !IsWindowVisible(h)) return true;
            string t = WindowText(h);
            if (t.Length == 0) return true;
            RECT r; GetWindowRect(h, out r);
            uint pid; GetWindowThreadProcessId(h, out pid);
            string proc = "";
            try { proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            outList.Add(string.Format("{0}|{1}|{2}|{3},{4},{5},{6}|{7}",
                h.ToInt64(), pid, proc, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, t));
            return true;
        }, IntPtr.Zero);
        return outList;
    }

    // Silent read of a text box: WM_GETTEXT does not touch the selection or the caret,
    // unlike select-all + copy, so it can be polled while a human is typing.
    const uint WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    static extern IntPtr SendMessageStr(IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    static extern IntPtr SendMessageInt(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string cls, string title);

    public static string GetEditText(IntPtr parent)
    {
        string[] classes = new string[] { "Edit", "RichEdit20W", "RichEdit50W", "RichEditD2DPT", "RICHEDIT60W" };
        foreach (string cls in classes)
        {
            IntPtr e = FindWindowEx(parent, IntPtr.Zero, cls, null);
            if (e == IntPtr.Zero) continue;
            int len = (int)SendMessageInt(e, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero);
            StringBuilder sb = new StringBuilder(len + 2);
            SendMessageStr(e, WM_GETTEXT, (IntPtr)sb.Capacity, sb);
            return sb.ToString();
        }
        return null;
    }
}
'@
}

# Best effort per-monitor-V2 first: with mixed-DPI monitors a system-DPI-aware process gets
# virtual (silently scaled) coordinates for any window on a differently-scaled monitor, and
# every click computed from them lands somewhere else. Falls back to the legacy call, which
# is what this script used before and which is correct on a single uniform-DPI desktop.
$dpiOk = $false
try { $dpiOk = [CuNat]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $dpiOk = $false }
if (-not $dpiOk) { [void][CuNat]::SetProcessDPIAware() }

function Get-ScreenRect {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    return New-Object psobject -Property @{ X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height }
}

function Get-CursorState {
    $p = New-Object CuNat+POINT
    [void][CuNat]::GetCursorPos([ref]$p)
    return $p
}

function Save-Shot([int]$sx, [int]$sy, [int]$sw, [int]$sh, [string]$outPath) {
    $bmp = New-Object System.Drawing.Bitmap($sw, $sh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($sx, $sy, 0, 0, $bmp.Size)
    if ($Grid -gt 0) {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, 255, 0, 0)), 1
        $penB = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 255, 0, 0)), 2
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 70, 70))
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(205, 0, 0, 0))
        $font = New-Object System.Drawing.Font 'Consolas', 26
        $fontB = New-Object System.Drawing.Font 'Consolas', 34, ([System.Drawing.FontStyle]::Bold)
        # Label EVERY line, not every other one. Interpolating a coordinate between two labels
        # that sit 2*Grid apart is guesswork, and guesswork is what puts the pointer on the
        # wrong button once the capture has been downscaled for viewing. The dark plate behind
        # each label keeps it readable on top of a light UI.
        for ($gx = 0; $gx -lt $sw; $gx += $Grid) {
            $vx = $sx + $gx
            $isMajor = ($vx % ($Grid * 2)) -eq 0
            $g.DrawLine($(if ($isMajor) { $penB } else { $pen }), $gx, 0, $gx, $sh)
            $label = [string]$vx
            $f = $(if ($isMajor) { $fontB } else { $font })
            $sz = $g.MeasureString($label, $f)
            $g.FillRectangle($bg, ($gx + 2), 2, $sz.Width, $sz.Height)
            $g.DrawString($label, $f, $brush, ($gx + 2), 2)
        }
        for ($gy = 0; $gy -lt $sh; $gy += $Grid) {
            $vy = $sy + $gy
            $isMajor = ($vy % ($Grid * 2)) -eq 0
            $g.DrawLine($(if ($isMajor) { $penB } else { $pen }), 0, $gy, $sw, $gy)
            $label = [string]$vy
            $f = $(if ($isMajor) { $fontB } else { $font })
            $sz = $g.MeasureString($label, $f)
            $g.FillRectangle($bg, 2, ($gy + 2), $sz.Width, $sz.Height)
            $g.DrawString($label, $f, $brush, 2, ($gy + 2))
        }
        $bg.Dispose(); $brush.Dispose(); $pen.Dispose(); $penB.Dispose(); $font.Dispose(); $fontB.Dispose()
    }
    $dir = Split-Path -Parent $outPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function Find-Window([string]$needle) {
    $rows = @()
    foreach ($l in [CuNat]::ListWindows($true)) {
        $f = $l -split '\|'
        # Not -like: a window title containing [ ] or * would otherwise be read as a wildcard.
        if ($f[4].IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $rows += , $f
    }
    if ($rows.Count -eq 0) { throw "no visible window title matching '$needle'" }
    # A minimized window keeps reporting a stale rect at -32000,-32000, and every click
    # aimed at that rect goes nowhere while looking like a pointer bug. Prefer a match that
    # is really on screen.
    $live = @($rows | Where-Object { $_[3] -notlike '-32000*' })
    if ($live.Count -gt 0) { return $live[0] }
    return $rows[0]
}

function Assert-ForegroundMatch([string]$Needle) {
    # -Expect enforcement, called by every input action before it injects anything at all.
    # Same match rule as Find-Window -Title, deliberately nothing more: an ordinal,
    # case-insensitive substring of the window's TITLE text (ListWindows field 4, i.e.
    # GetWindowTextW). Find-Window does not compare the process name, so neither does this.
    # On a mismatch nothing is injected and the action fails loudly instead of typing blind.
    if (-not $Needle) { return }
    $fgWin = [CuNat]::GetForegroundWindow()
    $fgTitle = [CuNat]::WindowText($fgWin)
    if ($fgTitle.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return }
    # One plain line for the caller (expected pattern, the window that really is foreground, and
    # the explicit statement that nothing was injected), then the throw every other refusal in
    # this file uses - so the exit code is non-zero and the activity chip reports it as an error.
    $msg = ("EXPECT MISMATCH: expected foreground window matching '{0}' but the foreground window is hwnd {1} '{2}' - no input was injected" -f $Needle, $fgWin.ToInt64(), $fgTitle)
    Write-Output $msg
    throw $msg
}

function Get-Vk([string]$name) {
    $n = $name.Trim().ToLowerInvariant()
    $map = @{
        'ctrl' = 0x11; 'control' = 0x11; 'shift' = 0x10; 'alt' = 0x12; 'win' = 0x5B; 'lwin' = 0x5B; 'rwin' = 0x5C;
        'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20;
        'backspace' = 0x08; 'back' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D; 'ins' = 0x2D;
        'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pgup' = 0x21; 'pagedown' = 0x22; 'pgdn' = 0x22;
        'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27;
        'capslock' = 0x14; 'printscreen' = 0x2C; 'scrolllock' = 0x91; 'pause' = 0x13; 'numlock' = 0x90;
        'minus' = 0xBD; 'equal' = 0xBB; 'comma' = 0xBC; 'period' = 0xBE; 'dot' = 0xBE; 'slash' = 0xBF;
        'backslash' = 0xDC; 'semicolon' = 0xBA; 'quote' = 0xDE; 'bracketleft' = 0xDB; 'bracketright' = 0xDD; 'grave' = 0xC0;
        'apps' = 0x5D; 'volume_mute' = 0xAD; 'volume_down' = 0xAE; 'volume_up' = 0xAF
    }
    if ($map.ContainsKey($n)) { return $map[$n] }
    if ($n -match '^f([1-9]|1[0-9]|2[0-4])$') { return 0x70 + ([int]$Matches[1] - 1) }
    if ($n.Length -eq 1) {
        $c = $n.ToUpperInvariant()[0]
        if ($c -match '[A-Z0-9]') { return [int][char]$c }
    }
    throw "unknown key name: $name"
}

$extendedKeys = @(0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22, 0x5B, 0x5C, 0x5D, 0x2C)

function Send-KeyCombo([string]$combo) {
    $parts = $combo -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $vks = @($parts | ForEach-Object { Get-Vk $_ })
    $mods = @(0x11, 0x10, 0x12, 0x5B, 0x5C)
    $held = @()
    foreach ($vk in $vks) {
        if ($mods -contains $vk) { [void][CuNat]::KeyEvent([uint16]$vk, $false, $false); $held += $vk }
    }
    foreach ($vk in $vks) {
        if ($mods -notcontains $vk) {
            $ext = $extendedKeys -contains $vk
            [void][CuNat]::KeyEvent([uint16]$vk, $false, $ext)
            Start-Sleep -Milliseconds 20
            [void][CuNat]::KeyEvent([uint16]$vk, $true, $ext)
        }
    }
    for ($i = $held.Count - 1; $i -ge 0; $i--) { [void][CuNat]::KeyEvent([uint16]$held[$i], $true, $false) }
}

function Send-Text([string]$s, [int]$delay) {
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq "`r") { continue }
        elseif ($ch -eq "`n") { [void][CuNat]::KeyEvent(0x0D, $false, $false); [void][CuNat]::KeyEvent(0x0D, $true, $false) }
        elseif ($ch -eq "`t") { [void][CuNat]::KeyEvent(0x09, $false, $false); [void][CuNat]::KeyEvent(0x09, $true, $false) }
        else { [void][CuNat]::UnicodeChar($ch, $false); [void][CuNat]::UnicodeChar($ch, $true) }
        if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    }
}

function Resolve-TargetHwnd {
    if ($Hwnd -gt 0) { return [IntPtr]$Hwnd }
    if ($Title) { $f = Find-Window $Title; return [IntPtr][long]$f[0] }
    return [CuNat]::GetForegroundWindow()
}

function Get-DescendantCount([IntPtr]$h) {
    try {
        $r = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        if (-not $r) { return 0 }
        return $r.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Count
    }
    catch { return 0 }
}

function Invoke-AccessibilityWake([IntPtr]$h, [int]$budgetMs) {
    # Chromium/Electron/web apps keep the accessibility engine off until an assistive
    # technology asks for an accessibility object, so their UIA tree is near-empty and the
    # only way to aim used to be eyeballing a downscaled screenshot. Poking every child
    # window with WM_GETOBJECT is what a screen reader does; the tree then builds lazily,
    # which is why this polls instead of trusting the first query.
    $before = Get-DescendantCount $h
    $answered = 0
    if ([CuNat]::PokeAccessible($h)) { $answered++ }
    foreach ($k in [CuNat]::ChildWindows($h)) { if ([CuNat]::PokeAccessible($k)) { $answered++ } }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $best = $before
    $stable = 0
    while ($sw.ElapsedMilliseconds -lt $budgetMs) {
        Start-Sleep -Milliseconds 200
        $n = Get-DescendantCount $h
        if ($n -gt $best) { $best = $n; $stable = 0 } else { $stable++ }
        # Rich tree that has stopped growing: done. Tiny tree that stopped growing: this
        # window simply has nothing to expose, do not burn the whole budget on it.
        if ($stable -ge 2 -and $best -ge 20) { break }
        if ($stable -ge 5) { break }
    }
    return New-Object psobject -Property @{
        answered = $answered
        before   = $before
        after    = $best
        waitedMs = [int]$sw.ElapsedMilliseconds
    }
}

function Get-UiaRoot {
    Add-Type -AssemblyName UIAutomationClient | Out-Null
    Add-Type -AssemblyName UIAutomationTypes | Out-Null
    # Deliberately not $h: at script scope $h IS the [int]$H parameter, and assigning to it
    # makes PowerShell convert the value to Int32 (or throw). See the note in param().
    $targetHwnd = Resolve-TargetHwnd
    if (-not $NoWake) { $script:WakeReport = Invoke-AccessibilityWake $targetHwnd $WakeMs }
    return [System.Windows.Automation.AutomationElement]::FromHandle($targetHwnd)
}

function Write-WakeReport {
    if (-not $script:WakeReport) { return }
    $w = $script:WakeReport
    if ($w.answered -eq 0) {
        Write-Output ("a11y     : window did not answer WM_GETOBJECT (it exposes no accessibility tree at all)")
    }
    elseif ($w.after -gt $w.before) {
        Write-Output ("a11y     : woke {0} hwnd(s), tree {1} -> {2} nodes in {3} ms" -f $w.answered, $w.before, $w.after, $w.waitedMs)
    }
    else {
        Write-Output ("a11y     : already awake ({0} nodes), no change needed" -f $w.after)
    }
}

function Test-OnScreen($r) {
    $sc = Get-ScreenRect
    if ($r.Width -le 0 -or $r.Height -le 0) { return $false }
    return ($r.Right -gt $sc.X -and $r.Bottom -gt $sc.Y -and $r.Left -lt ($sc.X + $sc.W) -and $r.Top -lt ($sc.Y + $sc.H))
}

function Get-MatchRank($r) {
    # 0 = fully on screen and clickable, 1 = partly off screen, 2 = no usable rectangle.
    # Ranking matters because a substring match often also hits a hidden or zero-size
    # duplicate, and acting on "the first hit" used to mean acting on that duplicate.
    if ($r.Width -le 0 -or $r.Height -le 0) { return 2 }
    $sc = Get-ScreenRect
    $fully = ($r.Left -ge $sc.X -and $r.Top -ge $sc.Y -and $r.Right -le ($sc.X + $sc.W) -and $r.Bottom -le ($sc.Y + $sc.H))
    if ($fully) { return 0 }
    if (Test-OnScreen $r) { return 1 }
    return 2
}

function Test-NameMatch($n, [string]$needle) {
    if ($null -eq $n) { return $false }
    if ($Exact) { return ($n -eq $needle) }
    # Deliberately not -like: a name containing [ ] or * would then be treated as a
    # wildcard pattern and match the wrong controls.
    return ($n.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-UiaMatches($root) {
    if (-not $Name) { throw 'uia needs -Name' }
    $rows = @()
    $i = 0
    foreach ($el in (Get-UiaCandidates $root)) {
        $i++
        try {
            if (-not (Test-NameMatch $el.Current.Name $Name)) { continue }
            $r = $el.Current.BoundingRectangle
        }
        catch { continue }
        $rows += New-Object psobject -Property @{ el = $el; src = $i; rank = (Get-MatchRank $r); rect = $r }
    }
    # Plain @() here, and @() again at each call site. Do NOT add a leading comma: 'return ,@()'
    # combined with the caller's @() nests the rows one level deep, and then every member access
    # becomes array arithmetic - which surfaced as
    # "Method invocation failed because [System.Object[]] does not contain a method named
    # 'op_Division'" from the rectangle maths, a long way from the real cause.
    return @($rows | Sort-Object rank, src)
}

function Format-Match($row, [int]$displayIndex) {
    $c = $row.el.Current
    $r = $row.rect
    $ct = ''
    try { $ct = $c.ControlType.ProgrammaticName -replace 'ControlType\.', '' } catch { }
    $onScreen = Test-OnScreen $r
    $click = ''
    if ($r.Width -gt 0 -and $r.Height -gt 0) {
        $click = "click {0},{1}" -f [int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)
    }
    else { $click = 'no clickable area' }
    return ("[{0}] {1,-14} | {2,-32} | {3},{4} {5}x{6} | onScreen={7} | {8}" -f `
        $displayIndex, $ct, (n0 $c.Name), [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height, $onScreen, $click)
}

function Get-UiaCandidates($root) {
    Add-Type -AssemblyName UIAutomationClient | Out-Null
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $out = @()
    foreach ($el in $all) {
        try {
            $n = $el.Current.Name
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $out += $el
        } catch { }
    }
    return $out
}

function Format-UiaElement($el) {
    $c = $el.Current
    $r = $c.BoundingRectangle
    $ct = ''
    try { $ct = $c.ControlType.ProgrammaticName -replace 'ControlType\.', '' } catch { }
    return ("{0,-14} | {1,-34} | id={2,-18} | {3},{4} {5}x{6}" -f $ct, (n0 $c.Name), (n0 $c.AutomationId), [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
}

function n0($v) { if ($null -eq $v) { return '' } $s = [string]$v; if ($s.Length -gt 34) { return $s.Substring(0, 33) + '~' } return $s }

function Invoke-UiaElement($el) {
    # A disabled control accepts a click and does nothing, which is indistinguishable from a
    # mis-aimed click unless it is said out loud.
    $warn = @()
    try {
        if (-not $el.Current.IsEnabled) { $warn += 'the element is DISABLED' }
        if ($el.Current.IsOffscreen) { $warn += 'the element reports IsOffscreen' }
    }
    catch { }

    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return ("InvokePattern" + $(if ($warn) { ' [' + ($warn -join '; ') + ']' } else { '' })) }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); return 'TogglePattern' }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return 'SelectionItemPattern' }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { $p.Expand(); return 'ExpandCollapsePattern' }
    $r = $el.Current.BoundingRectangle
    if ($r.Width -le 0 -or $r.Height -le 0) { throw 'element has no clickable area (empty rectangle)' }
    $cx = [int]($r.X + $r.Width / 2); $cy = [int]($r.Y + $r.Height / 2)
    # Refuse to click outside the desktop. A click aimed at a stale or off-screen rect used
    # to be sent anyway and simply vanished, which reads exactly like "the button is broken".
    $sc = Get-ScreenRect
    if ($cx -lt $sc.X -or $cy -lt $sc.Y -or $cx -ge ($sc.X + $sc.W) -or $cy -ge ($sc.Y + $sc.H)) {
        throw ("element centre {0},{1} is off the desktop - refusing to click into nowhere" -f $cx, $cy)
    }

    # Reverse-check the point BEFORE injecting, the way a click should always be checked: ask
    # UIA what really sits there. A bounding rectangle can be partly occluded, and
    # IsOffscreen=false does not mean "nothing is covering it".
    try {
        $atPoint = [System.Windows.Automation.AutomationElement]::FromPoint((New-Object System.Windows.Point($cx, $cy)))
        if ($atPoint) {
            $an = $atPoint.Current.Name
            $en = $el.Current.Name
            if ($an -ne $en -and -not [string]::IsNullOrWhiteSpace($an)) {
                $warn += ("the point is actually over '{0}'" -f (n0 $an))
            }
        }
    }
    catch { }

    [void][CuNat]::SetCursorPos($cx, $cy)
    # Settle longer than a bare SetCursorPos would need: web/Electron UI frequently reveals
    # or moves the real target on hover, and clicking too early hits the pre-hover layout.
    Start-Sleep -Milliseconds 120
    $acc = [int][CuNat]::MouseEvent([CuNat]::MOUSEEVENTF_LEFTDOWN, 0)
    Start-Sleep -Milliseconds 30
    $acc += [int][CuNat]::MouseEvent([CuNat]::MOUSEEVENTF_LEFTUP, 0)
    if ($acc -lt 2) { $warn += 'SendInput was blocked (higher-integrity target?)' }
    # Report what the point actually belongs to, so a miss is visible instead of silent.
    $owner = [CuNat]::TopLevelAt($cx, $cy)
    $how = ("mouse@{0},{1} over '{2}'" -f $cx, $cy, [CuNat]::WindowText($owner))
    if ($warn) { $how += '  WARNING: ' + ($warn -join '; ') }
    return $how
}

function Write-MatchNote($hits, [string]$needle, [bool]$explicitIndex) {
    # From Codex's review of this bug: when a locator matches more than one control, acting on    # the first one silently is how a click ends up on the wrong control. Say it out loud.
    if ($hits.Count -le 1) { return }
    if ($explicitIndex) { return }
    $others = @()
    for ($j = 1; $j -lt [Math]::Min($hits.Count, 5); $j++) {
        try { $others += ("[{0}] {1}" -f ($j + 1), (n0 $hits[$j].el.Current.Name)) } catch { }
    }
    Write-Output ("WARNING: {0} controls match '*{1}*' and no -Index was given - acting on [1]. Also matched: {2}" -f $hits.Count, $needle, ($others -join '; '))
}

# ---- activity chip ----------------------------------------------------------
# The user cannot watch progress when the harness is behind the window being driven, and raising
# it covers that window while any pointer movement fights the synthetic mouse. So every action
# posts one line to a status file that a tiny always-on-top, click-through, capture-excluded
# chip displays. Everything here is best-effort: the chip must never be able to break an action.
$script:StatusPath = Join-Path $env:TEMP 'cu-status.txt'
$script:StatusPidPath = Join-Path $env:TEMP 'cu-status.pid'
$script:StatusRunGapSec = 45

function Get-CuStep {
    # A step counter only means something inside one run, so it restarts after a long gap.
    try {
        if (-not (Test-Path -LiteralPath $script:StatusPath)) { return 1 }
        $parts = ([System.IO.File]::ReadAllText($script:StatusPath, [System.Text.Encoding]::UTF8)).Trim().Split('|')
        if ($parts.Count -lt 3) { return 1 }
        $stamp = 0L
        if (-not [long]::TryParse($parts[0], [ref]$stamp)) { return 1 }
        $prev = 0
        if (-not [int]::TryParse($parts[2], [ref]$prev)) { $prev = 0 }
        $ageSec = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $stamp) / 1000.0
        if ($ageSec -gt $script:StatusRunGapSec) { return 1 }
        return ($prev + 1)
    }
    catch { return 1 }
}

function Test-ChipRunning {
    # Fast path: the pid file the chip was recorded in.
    if (Test-Path -LiteralPath $script:StatusPidPath) {
        $old = (Get-Content -LiteralPath $script:StatusPidPath -ErrorAction SilentlyContinue) -join ''
        if ($old -match '^\d+$' -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) { return $true }
    }
    # Slow path, only when the fast one says no: the pid file can be missing or stale (it is only
    # a hint), and starting a second chip just stacks two identical pills on the same spot.
    # Ask the OS what is actually running before launching anything.
    #
    # Match the CLOSING QUOTE after the script name, not a bare 'cu-status.ps1' substring. A
    # substring match also hits any shell whose command line merely mentions this file - measured
    # the hard way: a diagnostic one-liner that grep'd for 'cu-status.ps1' matched its own
    # process, killed it, and produced a silent no-output failure that looked like a bug in the
    # chip launcher for a good while.
    try {
        $found = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $script:HostNames -contains $_.Name -and $_.ProcessId -ne $PID -and $_.CommandLine -match 'cu-status\.ps1"' })
        if ($found.Count -gt 0) {
            Set-Content -LiteralPath $script:StatusPidPath -Value $found[0].ProcessId -Encoding ascii
            return $true
        }
    }
    catch { }
    return $false
}

function Start-Detached([string]$cmdline, [string]$outTag) {
    # Launch a long-lived GUI helper so that it inherits NOTHING from the caller.
    #
    # Start-Process is not good enough here, and the failure is nasty and silent: the child keeps
    # the caller's stdout handle open for as long as it lives, so whoever ran cu.ps1 (a shell, an
    # agent, a batch file) never sees its pipe reach EOF and appears to hang with NO output at
    # all, long after cu.ps1 itself has exited. Win32_Process.Create goes through the service
    # host and gives the child a clean environment with no inherited handles.
    # Win32_Process.Create has no -WindowStyle equivalent, so the flag has to be part of the
    # command line - otherwise the helper comes up with a full console window sitting on the
    # user's desktop. Start-Process used to hide it; WMI does not.
    #
    # The host name is substituted rather than pattern-matched. The old code did
    # ($cmdline -replace '^powershell\s+', 'powershell -WindowStyle Hidden ') on a literal
    # 'powershell ...' command line; under pwsh that regex matches nothing, so the chip would
    # have appeared with a visible console window. Callers now pass the host name as $HostExe
    # and this function guarantees the hidden flag.
    $hostExe = $script:HostExe
    if ($cmdline -match '^pwsh(-preview)?\s+') { $hostExe = $Matches[0].Trim() }
    if ($cmdline -notmatch '-WindowStyle') {
        $cmdline = $hostExe + ' -WindowStyle Hidden ' + ($cmdline -replace '^\S+\s+', '')
    }
    # MEASURED FIX, 2026-09-26 - the second half of the paragraph above was not true in practice.
    #
    # Symptom: a caller that captures cu.ps1 through a pipe (an agent harness, a `| Out-Null`, a CI
    # step) waited for an EOF that never arrived, so the cu action looked hung forever with no
    # output. Measured twice: a piped `cu windows` did not return for 25-40 s, and killing the
    # helper released the caller within a second - proof the helper held the pipe.
    #
    # Cause: in this environment the CIM branch below does not succeed, so the Start-Process
    # fallback runs. That fallback has to pass the two redirect handles, which means the child is
    # created with bInheritHandles=TRUE - and that hands over EVERY inheritable handle we own,
    # including the caller's stdout pipe, no matter what the redirects say. (Verified by process
    # tree: the chip's parent was the cu.ps1 process itself, and its command line was the fallback
    # one, so WMI was never used.)
    #
    # Fix: clear HANDLE_FLAG_INHERIT on our own standard handles for the duration of the spawn, then
    # put it back. The helper then starts with clean stdio (the redirects) and the caller reaches
    # EOF as soon as cu.ps1 exits, while the helper itself stays long-lived as intended.
    if (-not ('CuNoInherit' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CuNoInherit {
    private const uint HANDLE_FLAG_INHERIT = 0x1;
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    private static readonly int[] Ids = new int[] { -10, -11, -12 };
    public static void ClearAll() {
        foreach (int id in Ids) {
            IntPtr h = GetStdHandle(id);
            if (h != IntPtr.Zero && h != new IntPtr(-1)) { try { SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0); } catch { } }
        }
    }
    public static void RestoreAll() {
        foreach (int id in Ids) {
            IntPtr h = GetStdHandle(id);
            if (h != IntPtr.Zero && h != new IntPtr(-1)) { try { SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT); } catch { } }
        }
    }
}
'@
    }
    try { [CuNoInherit]::ClearAll() } catch { }

    try {
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdline } -ErrorAction Stop
        if ($r -and $r.ProcessId) { try { [CuNoInherit]::RestoreAll() } catch { }; return [int]$r.ProcessId }
    }
    catch { }
    # Fallback: still redirect the streams so the child cannot hold a pipe it was not meant to.
    $newPid = 0
    try {
        $p = Start-Process -FilePath $hostExe -WindowStyle Hidden -PassThru `
            -ArgumentList ($cmdline -replace '^\S+\s+', '') `
            -RedirectStandardOutput (Join-Path $env:TEMP ("cu-{0}.out" -f $outTag)) `
            -RedirectStandardError (Join-Path $env:TEMP ("cu-{0}.err" -f $outTag))
        $newPid = [int]$p.Id
    }
    catch { $newPid = 0 }
    try { [CuNoInherit]::RestoreAll() } catch { }
    return $newPid
}

function Start-CuStatusChip {
    if ($NoChip) { return }
    $chip = Join-Path $PSScriptRoot 'cu-status.ps1'
    if (-not (Test-Path -LiteralPath $chip)) { return }
    if (Test-ChipRunning) { return }
    # Watchdog target: the harness window's process, so closing the harness takes the chip too.
    $watch = 0
    foreach ($l in [CuNat]::ListWindows($false)) {
        $f = $l -split '\|'
        if ($f[4] -match 'DeepSeek Harness') { $watch = [int]$f[1]; break }
    }
    $cmdline = '{0} -NoProfile -STA -ExecutionPolicy Bypass -File "{1}" -StatusFile "{2}"' -f $script:HostExe, $chip, $script:StatusPath
    if ($watch -gt 0) { $cmdline += (' -WatchPid {0}' -f $watch) }
    $newPid = Start-Detached $cmdline 'status'
    if ($newPid -gt 0) { Set-Content -LiteralPath $script:StatusPidPath -Value $newPid -Encoding ascii }
}

function Write-CuStatus([string]$state, [string]$message, [int]$step) {
    # Called twice per action (busy, then the result). -NoChip makes it a no-op.
    if ($NoChip) { return }
    try {
        if ($message.Length -gt 88) { $message = $message.Substring(0, 87) + '~' }
        $message = $message -replace '\|', '/' -replace "`r", ' ' -replace "`n", ' '
        $line = '{0}|{1}|{2}|{3}' -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), $state, $step, $message
        [System.IO.File]::WriteAllText($script:StatusPath, $line, (New-Object System.Text.UTF8Encoding($false)))
        Start-CuStatusChip
    }
    catch { }
}

function Get-CuActionLabel {
    $d = ''
    switch ($Action) {
        'uia' { $d = $Mode; if ($Name) { $d += ' ' + $Name } }
        'wake' { if ($Hwnd -gt 0) { $d = "hwnd $Hwnd" } elseif ($Title) { $d = $Title } }
        'click' { if ($PSBoundParameters.ContainsKey('X')) { $d = "$X,$Y" } }
        'move' { $d = "$X,$Y" }
        'drag' { $d = "$X1,$Y1 -> $X2,$Y2" }
        'type' { if ($Text) { $d = $Text } }
        'paste' { if ($Text) { $d = $Text } }
        'key' { $d = $Keys }
        'focus' { if ($Title) { $d = $Title } elseif ($Hwnd -gt 0) { $d = "hwnd $Hwnd" } }
        'shot' { if ($Title) { $d = $Title } elseif ($PSBoundParameters.ContainsKey('W')) { $d = "$W x $H" } else { $d = 'full screen' } }
        'windows' { $d = '' }
        'sleep' { $d = "$DelayMs ms" }
        'status' { $d = $Text }
    }
    if ($d) { return ("{0} {1}" -f $Action, $d) }
    return $Action
}

$script:CuLabel = Get-CuActionLabel
$script:CuStep = Get-CuStep
$script:CuError = $null
Write-CuStatus 'busy' $script:CuLabel $script:CuStep

try {

switch ($Action) {

    'info' {
        $s = Get-ScreenRect
        $p = Get-CursorState
        $fg = [CuNat]::GetForegroundWindow()
        Write-Output ("virtualScreen : {0}x{1} at {2},{3}" -f $s.W, $s.H, $s.X, $s.Y)
        Write-Output ("primaryScreen : {0}x{1}" -f [CuNat]::GetSystemMetrics(0), [CuNat]::GetSystemMetrics(1))
        Write-Output ("monitors      : {0}" -f [System.Windows.Forms.Screen]::AllScreens.Count)
        Write-Output ("cursor        : {0},{1}" -f $p.X, $p.Y)
        Write-Output ("foreground    : {0}" -f [CuNat]::WindowText($fg))
        Write-Output ("fgHwnd        : {0}" -f $fg.ToInt64())
        Write-Output ("powershell    : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
        Write-Output ("inputStruct   : {0} bytes" -f [CuNat]::InputSize())
    }

    'shot' {
        if (-not $Path) { $Path = Join-Path $env:TEMP ("cu-shot-{0:yyyyMMdd-HHmmss}.png" -f (Get-Date)) }
        # The capture deliberately does NOT touch the overlay: it used to mute it for the
        # duration of the shot, which made the effect blink out and back on every screenshot -
        # far more disruptive than the fog it avoided. The overlay stays exactly as it is, and
        # the screenshot simply contains it. Ambient fog only darkens the screen edges; the
        # centre of the screen stays clean, so captures stay readable. -KeepFx is kept as a
        # no-op for backwards compatibility.

        if ($Hwnd -gt 0) {
            $r = New-Object CuNat+RECT
            [void][CuNat]::GetWindowRect([IntPtr]$Hwnd, [ref]$r)
            Save-Shot $r.Left $r.Top ($r.Right - $r.Left) ($r.Bottom - $r.Top) $Path
        }
        elseif ($Title) {
            $f = Find-Window $Title
            $r = $f[3] -split ','
            Save-Shot ([int]$r[0]) ([int]$r[1]) ([int]$r[2]) ([int]$r[3]) $Path
        }
        elseif ($PSBoundParameters.ContainsKey('X') -or $PSBoundParameters.ContainsKey('Y') -or $PSBoundParameters.ContainsKey('W')) {
            $sx = if ($PSBoundParameters.ContainsKey('X')) { $X } else { 0 }
            $sy = if ($PSBoundParameters.ContainsKey('Y')) { $Y } else { 0 }
            $sc = Get-ScreenRect
            $sw = if ($PSBoundParameters.ContainsKey('W')) { $W } else { $sc.W - $sx }
            $sh = if ($PSBoundParameters.ContainsKey('H')) { $H } else { $sc.H - $sy }
            Save-Shot $sx $sy $sw $sh $Path
        }
        else {
            $sc = Get-ScreenRect
            Save-Shot $sc.X $sc.Y $sc.W $sc.H $Path
        }
        $fi = Get-Item $Path
        $img = [System.Drawing.Image]::FromFile($Path)
        Write-Output ("{0}  {1}x{2}  {3} KB" -f $fi.FullName, $img.Width, $img.Height, [math]::Round($fi.Length / 1KB))
        $img.Dispose()
    }

    'cursor' {
        $p = Get-CursorState
        Write-Output ("{0},{1}" -f $p.X, $p.Y)
    }

    'move' {
        if (-not $PSBoundParameters.ContainsKey('X')) { throw 'move needs -X -Y' }
        [void][CuNat]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds $DelayMs
        $p = Get-CursorState
        Write-Output ("cursor at {0},{1}" -f $p.X, $p.Y)
    }

    'click' {
        Assert-ForegroundMatch $Expect
        if ($PSBoundParameters.ContainsKey('X')) {
            $sc = Get-ScreenRect
            if ($X -lt $sc.X -or $Y -lt $sc.Y -or $X -ge ($sc.X + $sc.W) -or $Y -ge ($sc.Y + $sc.H)) {
                throw ("click target {0},{1} is outside the desktop {2},{3} {4}x{5} - refusing to click into nowhere" -f $X, $Y, $sc.X, $sc.Y, $sc.W, $sc.H)
            }
            [void][CuNat]::SetCursorPos($X, $Y)
            Start-Sleep -Milliseconds $DelayMs
            # SetCursorPos silently CLAMPS to the desktop. If that happened the click did not
            # land where it was aimed, and without this check the reported position looks fine.
            $now = Get-CursorState
            if ($now.X -ne $X -or $now.Y -ne $Y) {
                Write-Output ("WARNING: pointer clamped to {0},{1} instead of the requested {2},{3} - the click did NOT land where aimed" -f $now.X, $now.Y, $X, $Y)
            }
        }
        switch ($Button) {
            'left' { $down = [CuNat]::MOUSEEVENTF_LEFTDOWN; $up = [CuNat]::MOUSEEVENTF_LEFTUP }
            'right' { $down = [CuNat]::MOUSEEVENTF_RIGHTDOWN; $up = [CuNat]::MOUSEEVENTF_RIGHTUP }
            'middle' { $down = [CuNat]::MOUSEEVENTF_MIDDLEDOWN; $up = [CuNat]::MOUSEEVENTF_MIDDLEUP }
        }
        $times = if ($Double) { 2 } else { $Count }
        $accepted = 0
        $attempted = 0
        for ($i = 0; $i -lt $times; $i++) {
            $attempted++
            $accepted += [int][CuNat]::MouseEvent($down, 0)
            Start-Sleep -Milliseconds 15
            $accepted += [int][CuNat]::MouseEvent($up, 0)
            if ($i -lt $times - 1) { Start-Sleep -Milliseconds 60 }
        }
        $p = Get-CursorState
        # Name the window that received the click: a click that lands on the wrong window
        # otherwise looks exactly like a button that ignores input.
        $owner = [CuNat]::TopLevelAt($p.X, $p.Y)
        Write-Output ("{0} click x{1} at {2},{3} over '{4}'" -f $Button, $times, $p.X, $p.Y, [CuNat]::WindowText($owner))
        # SendInput reports how many events it accepted. Zero means the click was swallowed -
        # typically UIPI refusing input aimed at a higher-integrity (elevated) window - and
        # nothing about the coordinates would have revealed that.
        if ($accepted -lt ($attempted * 2)) {
            Write-Output ("WARNING: SendInput accepted only {0} of {1} events - the input was blocked, most likely because the target window runs at a higher integrity level (elevated). Coordinates were fine." -f $accepted, ($attempted * 2))
        }
    }

    'drag' {
        Assert-ForegroundMatch $Expect
        [void][CuNat]::SetCursorPos($X1, $Y1)
        Start-Sleep -Milliseconds 120
        [void][CuNat]::MouseEvent([CuNat]::MOUSEEVENTF_LEFTDOWN, 0)
        Start-Sleep -Milliseconds 80
        $steps = 18
        for ($i = 1; $i -le $steps; $i++) {
            $nx = [int]($X1 + ($X2 - $X1) * $i / $steps)
            $ny = [int]($Y1 + ($Y2 - $Y1) * $i / $steps)
            [void][CuNat]::SetCursorPos($nx, $ny)
            Start-Sleep -Milliseconds 12
        }
        [void][CuNat]::MouseEvent([CuNat]::MOUSEEVENTF_LEFTUP, 0)
        Write-Output ("dragged {0},{1} -> {2},{3}" -f $X1, $Y1, $X2, $Y2)
    }

    'scroll' {
        Assert-ForegroundMatch $Expect
        if ($PSBoundParameters.ContainsKey('X')) {
            [void][CuNat]::SetCursorPos($X, $Y)
            Start-Sleep -Milliseconds $DelayMs
        }
        [void][CuNat]::MouseEvent([CuNat]::MOUSEEVENTF_WHEEL, $Amount * 120)
        Write-Output ("scrolled {0} notch(es)" -f $Amount)
    }

    'type' {
        Assert-ForegroundMatch $Expect
        if (-not $Text) { throw 'type needs -Text' }
        Send-Text $Text $DelayMs
        Write-Output ("typed {0} char(s)" -f $Text.Length)
    }

    'paste' {
        Assert-ForegroundMatch $Expect
        if (-not $Text) { throw 'paste needs -Text' }
        $old = $null
        try { $old = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
        Set-Clipboard -Value $Text
        Start-Sleep -Milliseconds 90
        Send-KeyCombo 'ctrl+v'
        Start-Sleep -Milliseconds 80
        if ($null -ne $old) { try { Set-Clipboard -Value $old -ErrorAction SilentlyContinue } catch { } }
        Write-Output ("pasted {0} char(s)" -f $Text.Length)
    }

    'key' {
        Assert-ForegroundMatch $Expect
        if (-not $Keys) { throw 'key needs -Keys, e.g. "ctrl+s"' }
        Send-KeyCombo $Keys
        Write-Output ("sent keys: {0}" -f $Keys)
    }

    'windows' {
        $rows = @()
        foreach ($l in [CuNat]::ListWindows(-not $All)) {
            $f = $l -split '\|'
            $rows += New-Object psobject -Property @{ hwnd = $f[0]; pid = $f[1]; process = $f[2]; rect = $f[3]; title = $f[4] }
        }
        if ($Json) {
            foreach ($r in $rows) { Write-Output (ConvertTo-Json -InputObject $r -Compress) }
            return
        }
        $rows | Sort-Object process | Format-Table -AutoSize | Out-String -Width 400 | Write-Output
        Write-Output ("total {0} window(s)" -f $rows.Count)
    }

    'focus' {
        # $win, NOT $h: at script scope $h is the [int]$H parameter (PowerShell variable names
        # are case-insensitive), and an HWND stored there would be silently truncated.
        if ($Hwnd -gt 0) { $win = [IntPtr]$Hwnd }
        elseif ($Title) { $f = Find-Window $Title; $win = [IntPtr][long]$f[0] }
        else { throw 'focus needs -Title or -Hwnd' }
        # SW_RESTORE (9) also UN-maximizes a maximized window, which silently changes the
        # geometry every later coordinate click depends on. Only restore when actually minimized.
        if ([CuNat]::IsIconic($win)) { [void][CuNat]::ShowWindow($win, 9) } else { [void][CuNat]::ShowWindow($win, 5) }
        [void][CuNat]::SetForegroundWindow($win)
        Start-Sleep -Milliseconds 300
        Write-Output ("focused: {0}" -f [CuNat]::WindowText($win))
    }

    'clip' {
        if ($PSBoundParameters.ContainsKey('Text')) { Set-Clipboard -Value $Text; Write-Output ("clipboard set ({0} chars)" -f $Text.Length) }
        else { $c = Get-Clipboard -Raw; Write-Output $c }
    }

    'sleep' {
        Start-Sleep -Milliseconds $DelayMs
        Write-Output ("slept {0} ms" -f $DelayMs)
    }

    'fxon' {
        $fx = Join-Path $PSScriptRoot 'fx.ps1'
        if (-not (Test-Path $fx)) { throw "missing overlay script: $fx" }
        $pidFile = Join-Path $env:TEMP 'cu-fx.pid'
        if (Test-Path $pidFile) {
            $old = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue) -join ''
            if ($old -match '^\d+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
        }
        # Watchdog target: the harness window's process, so closing the harness takes the overlay
        # down with it rather than stranding fog on the screen with nobody able to dismiss it.
        $watch = $WatchPid
        if ($watch -lt 0) {
            $watch = 0
            foreach ($l in [CuNat]::ListWindows($false)) {
                $f = $l -split '\|'
                if ($f[4] -match 'DeepSeek Harness') { $watch = [int]$f[1]; break }
            }
        }
        # Started detached (see Start-Detached): a long-lived overlay that inherited the caller's
        # stdout would keep that pipe open and make the caller look hung.
        $fxCmd = '{0} -NoProfile -STA -ExecutionPolicy Bypass -File "{1}" -DurationSec {2}' -f $script:HostExe, $fx, $DurationSec
        if ($DimPct -ge 0) { $fxCmd += (' -Dim {0}' -f ($DimPct / 100.0)) }
        if ($DimAfter -ge 0) { $fxCmd += (' -DimAfterSec {0}' -f $DimAfter) }
        if ($watch -gt 0) { $fxCmd += (' -WatchPid {0}' -f $watch) }
        # Per-run headline. It has to travel as an argument, quoted by hand: the value routinely
        # contains spaces, and an unquoted -Text is the exact class of bug that once made a
        # caller's '-Text "cu-mcp boot"' fail parameter binding outright. Without this, a caller
        # could pass a headline and see nothing change (the words come from a UTF-8 file by
        # default, which stays the fallback here).
        if (-not [string]::IsNullOrWhiteSpace($Text)) {
            $fxCmd += (' -Text "{0}"' -f ($Text -replace '"', ''))
        }
        $p = New-Object psobject -Property @{ Id = (Start-Detached $fxCmd 'fx') }
        Set-Content -LiteralPath $pidFile -Value $p.Id -Encoding ascii
        Write-Output ("fx on: takeover overlay pid {0}, stays up until fxoff/watchdog (backstop {1}s), click-through, never steals focus" -f $p.Id, $DurationSec)
        Write-Output ("         ambient: full strength for {0}s, then eases to {1} and stays there (screenshots do NOT interrupt it)" -f $(if ($DimAfter -ge 0) { $DimAfter } else { 6 }), $(if ($DimPct -ge 0) { "$DimPct% (explicit)" } else { '10% (fx.ps1 default)' }))
    }

    'fxoff' {
        $pidFile = Join-Path $env:TEMP 'cu-fx.pid'
        if (Test-Path $pidFile) {
            $old = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue) -join ''
            if ($old -match '^\d+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            # Clear the legacy mute flag: older builds of `shot` created one, and a leftover
            # file must never influence a later overlay (fx.ps1 clears it at startup anyway).
            Remove-Item -LiteralPath (Join-Path $env:TEMP 'cu-fx.mute') -Force -ErrorAction SilentlyContinue
            Write-Output 'fx off - overlay gone, screen restored'
        }
        else { Write-Output 'fx off (nothing was running)' }
    }

    'fxstatus' {
        # Is the takeover overlay up right now? Added so a caller can decide whether turning it
        # on would RESTART the intro animation: `fxon` always starts a fresh overlay, which is
        # visible as the fog re-condensing, so a batch must not call it blindly on every step.
        # The pid file is only a hint (it can be stale), so the process is checked for real.
        $pidFile = Join-Path $env:TEMP 'cu-fx.pid'
        $fxPid = 0
        if (Test-Path $pidFile) {
            $old = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue) -join ''
            if ($old -match '^\d+$') { $fxPid = [int]$old }
        }
        $alive = $false
        if ($fxPid -gt 0) { $alive = [bool](Get-Process -Id $fxPid -ErrorAction SilentlyContinue) }
        if ($Json) { Write-Output ('{{"on":{0},"pid":{1}}}' -f $(if ($alive) { 'true' } else { 'false' }), $fxPid) }
        elseif ($alive) { Write-Output ("fx on - overlay pid {0}" -f $fxPid) }
        else { Write-Output 'fx off (nothing is running)' }
    }

    'wtext' {
        if ($Hwnd -gt 0) { $win = [IntPtr]$Hwnd }
        elseif ($Title) { $f = Find-Window $Title; $win = [IntPtr][long]$f[0] }
        else { $win = [CuNat]::GetForegroundWindow() }
        $t = [CuNat]::GetEditText($win)
        if ($null -eq $t) { Write-Output 'NO_EDIT_CONTROL' }
        else { Write-Output $t }
    }

    'show' {
        if ($Hwnd -gt 0) { $win = [IntPtr]$Hwnd }
        elseif ($Title) { $f = Find-Window $Title; $win = [IntPtr][long]$f[0] }
        else { $win = [CuNat]::GetForegroundWindow() }
        $code = 9
        switch ($Mode) {
            'minimize' { $code = 6 }
            'maximize' { $code = 3 }
            'restore' { $code = 9 }
            'hide' { $code = 0 }
            'shows' { $code = 5 }
            'normal' { $code = 1 }
        }
        [void][CuNat]::ShowWindow($win, $code)
        Start-Sleep -Milliseconds 350
        Write-Output ("show {0} (cmd {1}) -> '{2}' iconic={3}" -f $Mode, $code, [CuNat]::WindowText($win), [CuNat]::IsIconic($win))
    }

    'place' {
        # $win, NOT $h: $h and the [int]$H height parameter are the SAME variable, so the old
        # code passed the window handle as the height and asked for a 100000-pixel-tall window.
        if ($Hwnd -gt 0) { $win = [IntPtr]$Hwnd }
        elseif ($Title) { $f = Find-Window $Title; $win = [IntPtr][long]$f[0] }
        else { $win = [CuNat]::GetForegroundWindow() }
        if (-not $PSBoundParameters.ContainsKey('Y')) { throw 'place needs -X -Y -W -H' }
        [void][CuNat]::ShowWindow($win, 9)
        Start-Sleep -Milliseconds 200
        [void][CuNat]::MoveWindow($win, $X, $Y, $W, $H, $true)
        Start-Sleep -Milliseconds 400
        $r = New-Object CuNat+RECT
        [void][CuNat]::GetWindowRect($win, [ref]$r)
        Write-Output ("placed '{0}' -> {1},{2} {3}x{4}" -f [CuNat]::WindowText($win), $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    }

    'uia' {
        Add-Type -AssemblyName UIAutomationClient | Out-Null
        Add-Type -AssemblyName UIAutomationTypes | Out-Null
        $root = Get-UiaRoot
        Write-WakeReport
        switch ($Mode) {

            'tree' {
                Write-Output ("root: [{0}] {1}" -f $root.Current.ControlType.ProgrammaticName, $root.Current.Name)
                $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
                $script:nodeCount = 0
                $script:totalCount = 0
                function Walk($el, $lvl) {
                    if ($lvl -gt $Depth -or $script:totalCount -gt 600) { return }
                    $kid = $walker.GetFirstChild($el)
                    while ($kid -ne $null) {
                        try {
                            $c = $kid.Current
                            $script:totalCount++
                            $named = -not [string]::IsNullOrWhiteSpace($c.Name)
                            if ($named) { $script:nodeCount++ }
                            if ($named -or $All) {
                                $r = $c.BoundingRectangle
                                $ct = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''
                                Write-Output ("{0}{1} | {2} | id={3} | {4},{5} {6}x{7}" -f ('  ' * $lvl), $ct, (n0 $c.Name), $c.AutomationId, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
                            }
                            Walk $kid ($lvl + 1)
                        } catch { }
                        $kid = $walker.GetNextSibling($kid)
                    }
                }
                Walk $root 0
                Write-Output ("named nodes: {0} / total descendants walked: {1}" -f $script:nodeCount, $script:totalCount)
                if ($script:totalCount -eq 0) {
                    Write-Output 'HINT: still no tree after the wake-up. Either this window genuinely exposes none, or the content lives in a different window of the same app - list the app''s windows and try the one that is on screen.'
                }
            }

            'find' {
                $hits = @(Get-UiaMatches $root)
                $i = 0
                foreach ($row in $hits) {
                    $i++
                    Write-Output (Format-Match $row $i)
                    if ($i -ge 40) { Write-Output '... more matches truncated'; break }
                }
                Write-Output ("matches: {0}  (best first: on-screen and clickable ranked above hidden duplicates)" -f $hits.Count)
                if ($hits.Count -eq 0) {
                    Write-Output ("HINT: nothing matched '*{0}'. Try a shorter substring, or drop -Exact, or run -Mode tree to see the real names." -f $Name)
                }
                else {
                    Write-Output ("NEXT: 'uia -Mode click -Name `"{0}`" -Index <n>' acts on match [n]; the 'click x,y' on each line is the exact point." -f $Name)
                }
            }

            'click' {
                $hits = @(Get-UiaMatches $root)
                Write-MatchNote $hits $Name ($PSBoundParameters.ContainsKey('Index'))
                if ($hits.Count -eq 0) { throw "no UIA element matching '*$Name*'" }
                if ($Index -gt $hits.Count) { throw ("only {0} match(es) for '*{1}', requested -Index {2}" -f $hits.Count, $Name, $Index) }
                $row = $hits[$Index - 1]
                $how = Invoke-UiaElement $row.el
                Write-Output ("clicked {0} via {1} : '{2}'" -f (Format-Match $row $Index), $how, (n0 $row.el.Current.Name))
            }

            'settext' {
                if (-not $PSBoundParameters.ContainsKey('Text')) { throw 'uia settext needs -Text' }
                $hits = @(Get-UiaMatches $root)
                Write-MatchNote $hits $Name ($PSBoundParameters.ContainsKey('Index'))
                if ($hits.Count -eq 0) { throw "no UIA element matching '*$Name*'" }
                if ($Index -gt $hits.Count) { throw ("only {0} match(es) for '*{1}', requested -Index {2}" -f $hits.Count, $Name, $Index) }
                $row = $hits[$Index - 1]
                $el = $row.el
                $p = $null
                if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) {
                    $p.SetValue($Text)
                    Write-Output ("set value of '{0}' to {1} chars via ValuePattern" -f (n0 $el.Current.Name), $Text.Length)
                }
                else {
                    # A contenteditable (very common on the web and in Electron) exposes no
                    # ValuePattern but does accept focus and keystrokes; saying so is far more
                    # useful than a bare "no ValuePattern".
                    $focused = $false
                    try { $el.SetFocus(); $focused = $true } catch { }
                    Write-Output ("'{0}' has no ValuePattern - it is probably a contenteditable." -f (n0 $el.Current.Name))
                    Write-Output ("  focused={0}. Next: 'type -Text `"...`"' or 'paste -Text `"...`' to put text in it." -f $focused)
                }
            }

            'focus' {
                $hits = @(Get-UiaMatches $root)
                Write-MatchNote $hits $Name ($PSBoundParameters.ContainsKey('Index'))
                if ($hits.Count -eq 0) { throw "no UIA element matching '*$Name*'" }
                if ($Index -gt $hits.Count) { throw ("only {0} match(es) for '*{1}', requested -Index {2}" -f $hits.Count, $Name, $Index) }
                $el = $hits[$Index - 1].el
                $el.SetFocus()
                Write-Output ("focused '{0}'" -f (n0 $el.Current.Name))
            }

            default { throw "unknown uia mode: $Mode (tree|find|click|settext|focus)" }
        }
    }

    'wake' {
        # Explicit control over the accessibility wake-up, for diagnosing an app that still
        # looks empty: reports how many hwnds answered and what the tree did.
        $targetHwnd = Resolve-TargetHwnd
        Write-Output ("target   : [{0}] {1}" -f [CuNat]::ClassOf($targetHwnd), [CuNat]::WindowText($targetHwnd))
        $kids = [CuNat]::ChildWindows($targetHwnd)
        Write-Output ("children : {0}" -f $kids.Count)
        foreach ($k in $kids) { Write-Output ("  {0,-10} [{1}]" -f $k.ToInt64(), [CuNat]::ClassOf($k)) }
        $report = Invoke-AccessibilityWake $targetHwnd $WakeMs
        Write-Output ("answered : {0} hwnd(s)" -f $report.answered)
        Write-Output ("tree     : {0} -> {1} nodes in {2} ms" -f $report.before, $report.after, $report.waitedMs)
        if ($report.after -le $report.before) {
            Write-Output 'NOTE     : the tree did not grow. The content may live in a sibling window -'
            Write-Output '           run "windows -Json" and wake the window that is actually on screen.'
        }
    }

    'status' {
        # Post an arbitrary progress line to the chip. This is for the phases that are NOT
        # computer-use - waiting on an API, generating a file, thinking - so that "is it still
        # working?" has an answer even when no window is being clicked.
        #   status -Text "generating image 3/8"
        #   status -State done -Text "all finished"
        if (-not $Text) { throw 'status needs -Text' }
        # announced by the wrapper below as well; this action's own line is the useful one
        Write-Output ("posted: [{0}] {1}" -f $State, $Text)
    }
}

}
catch {
    $script:CuError = $_.Exception.Message
    throw
}
finally {
    if ($script:CuError) {
        Write-CuStatus 'err' ($script:CuLabel + ' FAILED: ' + $script:CuError) $script:CuStep
    }
    elseif ($Action -eq 'status') {
        # let the caller choose the state; anything else would overwrite "done" with "ok"
        Write-CuStatus $State $Text $script:CuStep
    }
    else {
        Write-CuStatus 'ok' $script:CuLabel $script:CuStep
    }
}
