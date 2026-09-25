# cu-status.ps1 - tiny "DaFeiYu is working" activity chip.
#
# WHY THIS EXISTS
# While computer-use is running the harness window is usually behind whatever is being driven,
# so the user cannot see progress - and raising it would cover the very window being clicked,
# while any mouse movement fights the synthetic pointer. This chip is the third option: one line
# of text, always on top, saying what is happening right now.
#
# IT CANNOT INTERFERE, BY CONSTRUCTION
#   * WS_EX_TRANSPARENT  - click-through: every click passes to whatever is underneath
#   * WS_EX_NOACTIVATE   - never takes focus, so it can never steal a keystroke
#   * ShowActivated=false, IsHitTestVisible=false - belt and braces on the same two promises
#   * WS_EX_TOOLWINDOW   - no taskbar button, no alt-tab entry
#   * SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) - VISIBLE ON SCREEN, INVISIBLE TO SCREEN
#     CAPTURE. This is the important one: cu.ps1 screenshots the desktop constantly, and without
#     it the chip would sit inside every screenshot the agent reads.
#
# WHY THIS WINDOW IS NOT TRANSLUCENT (do not "fix" this)
# Measured on this machine with _dev/probe-wda.ps1:
#     plain window (AllowsTransparency=false): SetWindowDisplayAffinity -> True
#     layered window (AllowsTransparency=true): SetWindowDisplayAffinity -> False, error 8
# The call simply does not support layered windows, and WPF only gives real per-pixel
# translucency to a layered window. So it is either a pretty translucent chip that sits inside
# every screenshot the agent takes, or an opaque chip that the agent cannot see at all. The
# whole point of this thing is to not disturb the agent, so: opaque. The rounded shape comes
# from a window region (SetWindowRgn) instead, which layered windows are not needed for.
#
# LIFETIME
# It polls a status file, so cu.ps1 only ever writes one line of text and never waits for this
# process. It dims when nothing happens, hides and exits when the run looks finished, and also
# dies with the harness that owns it.

[CmdletBinding()]
param(
    [string]$StatusFile = "",
    # bc = bottom centre (default). The corners are all occupied on this desktop: the Codex pet
    # parks bottom-right as its own topmost window, a maximised window puts its minimise/close
    # buttons top-right, and the fx overlay headline sits top-centre. Bottom-centre is the one
    # strip that is normally just wallpaper, and it is the farthest from anything clickable.
    [string]$Corner = "bc",
    [int]$MarginX = 18,
    [int]$MarginY = 14,
    [double]$IdleFadeSec = 4.0,
    [int]$IdleExitSec = 180,
    [string]$SessionFile = '',
    [string]$SessionId = '',
    [int]$WatchPid = 0,
    [switch]$NoCaptureExclude
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cu-session.ps1')
trap {
    [IO.File]::AppendAllText((Join-Path $script:CuRuntimeDir 'cu-status.ps1.error.log'), ($_ | Out-String))
    exit 1
}
$script:sessionCheckAt = [DateTime]::MinValue
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI codepage, which
# corrupts non-ASCII source and breaks parsing. All Chinese text arrives at runtime through the
# UTF-8 status file, never as a literal in this file.

if ([string]::IsNullOrWhiteSpace($StatusFile)) { $StatusFile = Join-Path $env:TEMP 'cu-status.txt' }
$script:StatusPath = $StatusFile

# A hidden GUI process has nowhere to print, so progress goes to a one-line log file.
$script:LogPath = Join-Path $env:TEMP 'cu-status.log'
function Write-ChipLog([string]$t) {
    try {
        [System.IO.File]::WriteAllText($script:LogPath,
            ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

if (-not ('CsNat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CsNat {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
    // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    public const uint SWP_QUIET = 0x0001 | 0x0002 | 0x0010;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static int LastError() { return Marshal.GetLastWin32Error(); }
}
'@
}

# ---- geometry ---------------------------------------------------------------
# WorkArea is already in DIPs and already excludes the taskbar, so bottom-anchored placement
# does not need to guess how tall the taskbar is on this machine.
$wa = [Windows.SystemParameters]::WorkArea
$script:corner = $Corner.ToLowerInvariant()

$colBg      = [Windows.Media.Color]::FromArgb(255, 9, 22, 36)
$colBgIdle  = [Windows.Media.Color]::FromArgb(255, 16, 24, 33)
$colText    = [Windows.Media.Color]::FromArgb(255, 234, 245, 255)
$colTextIdle = [Windows.Media.Color]::FromArgb(255, 118, 143, 165)
$colAccent  = [Windows.Media.Color]::FromArgb(255, 63, 169, 245)
$colOk      = [Windows.Media.Color]::FromArgb(255, 90, 220, 150)
$colErr     = [Windows.Media.Color]::FromArgb(255, 255, 110, 110)
$colIdleEdge = [Windows.Media.Color]::FromArgb(255, 44, 66, 88)

# ---- visuals ----------------------------------------------------------------
$border = New-Object Windows.Controls.Border
$border.CornerRadius = New-Object Windows.CornerRadius(18)
$border.Background = New-Object Windows.Media.SolidColorBrush $colBg
$border.BorderThickness = New-Object Windows.Thickness(1)
$border.BorderBrush = New-Object Windows.Media.SolidColorBrush $colAccent
$border.Padding = New-Object Windows.Thickness(14, 8, 16, 8)

$row = New-Object Windows.Controls.StackPanel
$row.Orientation = [Windows.Controls.Orientation]::Horizontal
$border.Child = $row

# animated activity dot
$dotWrap = New-Object Windows.Controls.Grid
$dotWrap.Width = 18
$dotWrap.Height = 18
$dotWrap.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
$dotWrap.VerticalAlignment = [Windows.VerticalAlignment]::Center
$dot = New-Object Windows.Shapes.Ellipse
$dot.Width = 10
$dot.Height = 10
$dot.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
$dot.VerticalAlignment = [Windows.VerticalAlignment]::Center
$dot.Fill = New-Object Windows.Media.SolidColorBrush $colAccent
[void]$dotWrap.Children.Add($dot)
[void]$row.Children.Add($dotWrap)

$label = New-Object Windows.Controls.TextBlock
$label.FontFamily = New-Object Windows.Media.FontFamily("Microsoft YaHei UI, Microsoft YaHei, Segoe UI")
$label.FontSize = 13.5
$label.Foreground = New-Object Windows.Media.SolidColorBrush $colText
$label.VerticalAlignment = [Windows.VerticalAlignment]::Center
$label.MaxWidth = 460
$label.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
$label.Text = "DaFeiYu"
[void]$row.Children.Add($label)

$stepText = New-Object Windows.Controls.TextBlock
$stepText.FontFamily = New-Object Windows.Media.FontFamily("Microsoft YaHei UI, Microsoft YaHei, Segoe UI")
$stepText.FontSize = 11.5
$stepText.Margin = New-Object Windows.Thickness(14, 0, 0, 0)
$stepText.VerticalAlignment = [Windows.VerticalAlignment]::Center
$stepText.Foreground = New-Object Windows.Media.SolidColorBrush $colTextIdle
$stepText.Text = ""
[void]$row.Children.Add($stepText)

# ---- window -----------------------------------------------------------------
$win = New-Object Windows.Window
$win.WindowStyle = [Windows.WindowStyle]::None
$win.AllowsTransparency = $false          # see the header: required for capture exclusion
$win.Background = New-Object Windows.Media.SolidColorBrush $colBg
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.IsHitTestVisible = $false
$win.ResizeMode = [Windows.ResizeMode]::NoResize
$win.SizeToContent = [Windows.SizeToContent]::WidthAndHeight
$win.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
$win.Content = $border
# Do NOT pre-set Visibility=Hidden here. Measured the hard way: a Window created hidden makes
# ShowDialog() return immediately, so the dialog never runs its dispatcher loop - the process
# exits in a few milliseconds, the timer never ticks once, and the only symptom is a chip that
# never appears with no error anywhere. Position is estimated below and corrected in Loaded.
$win.Left = $wa.Left + ($wa.Width - 380) / 2
$win.Top = $wa.Bottom - 40 - $MarginY

function Get-WinHandle {
    if (-not $win) { return [IntPtr]::Zero }
    $helper = New-Object Windows.Interop.WindowInteropHelper($win)
    return $helper.Handle
}

function Update-Region {
    # Round the window with a real region. The ellipse size passed to CreateRoundRectRgn is the
    # DIAMETER, so a radius of half the height gives a clean pill.
    try {
        $h = Get-WinHandle
        if ($h -eq [IntPtr]::Zero) { return }
        $r = New-Object CsNat+RECT
        if (-not [CsNat]::GetClientRect($h, [ref]$r)) { return }
        $w = $r.Right - $r.Left
        $ht = $r.Bottom - $r.Top
        if ($w -le 2 -or $ht -le 2) { return }
        $rad = [int]$ht
        $rgn = [CsNat]::CreateRoundRectRgn(0, 0, $w + 1, $ht + 1, $rad, $rad)
        if ($rgn -ne [IntPtr]::Zero) { [void][CsNat]::SetWindowRgn($h, $rgn, $true) }
    }
    catch { }
}

function Set-Position {
    if ($win.ActualWidth -le 0) { return }
    $c = $script:corner
    if ($c -eq 'bc') { $x = $wa.Left + ($wa.Width - $win.ActualWidth) / 2 }
    elseif ($c -like '*l') { $x = $wa.Left + $MarginX }
    else { $x = $wa.Right - $win.ActualWidth - $MarginX }
    if ($c -like 't*') { $y = $wa.Top + $MarginY }
    else { $y = $wa.Bottom - $win.ActualHeight - $MarginY }
    $win.Left = $x
    $win.Top = $y
}

function Assert-Topmost {
    # The Codex desktop pet is also a topmost window, and among topmost windows the last one to
    # claim the top wins. Without re-asserting periodically the chip slides underneath it, which
    # looks exactly like "the indicator vanished". SWP_NOACTIVATE keeps the no-focus promise.
    try {
        $h = Get-WinHandle
        if ($h -ne [IntPtr]::Zero) {
            [void][CsNat]::SetWindowPos($h, [CsNat]::HWND_TOPMOST, 0, 0, 0, 0, [CsNat]::SWP_QUIET)
        }
    }
    catch { }
}

$win.Add_SourceInitialized({
        $h = (New-Object Windows.Interop.WindowInteropHelper($win)).Handle
        $ex = [CsNat]::GetWindowLong($h, -20)
        # WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
        # (no WS_EX_LAYERED: it would silently break the capture exclusion below)
        [void][CsNat]::SetWindowLong($h, -20, ($ex -bor 0x20 -bor 0x08000000 -bor 0x80))
        if (-not $NoCaptureExclude) {
            # Retried on the first ticks too: the call can be refused while the window is still
            # being created, and it is worth logging which attempt the OS accepted.
            $script:wdaHwnd = $h
            $script:wdaOk = [CsNat]::SetWindowDisplayAffinity($h, [CsNat]::WDA_EXCLUDEFROMCAPTURE)
            $script:wdaErr = [CsNat]::LastError()
            Write-ChipLog ("sourceInit hwnd={0} ex=0x{1:X} wda={2}/err={3}" -f $h.ToInt64(), $ex, $script:wdaOk, $script:wdaErr)
        }
    })

$win.Add_Loaded({
        Update-Region
        Set-Position
    })
$win.Add_SizeChanged({ Update-Region; Set-Position })

# ---- state ------------------------------------------------------------------
$script:lastWrite = [DateTime]::MinValue
$script:lastSeenTicks = 0
$script:state = 'busy'
$script:step = 0
$script:tick = 0
$script:closing = $false
$script:dimmed = $false
$script:wdaHwnd = [IntPtr]::Zero
$script:wdaOk = $false
$script:wdaErr = 0

$script:pulse = New-Object Windows.Media.Animation.DoubleAnimation(0.25, 1.0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(620)))
$script:pulse.AutoReverse = $true
$script:pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$script:pulsing = $false

function Set-DotColor([Windows.Media.Color]$c) {
    $dot.Fill = New-Object Windows.Media.SolidColorBrush $c
}

function Start-Pulse {
    if ($script:pulsing) { return }
    $dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $script:pulse)
    $script:pulsing = $true
}
function Stop-Pulse([double]$solid) {
    if ($script:pulsing) { $dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null) }
    $script:pulsing = $false
    $dot.Opacity = $solid
}

function Set-Dimmed([bool]$on) {
    # There is no window-level opacity to animate on a non-layered window, so "asleep" is shown
    # by draining the colour out of the chip instead.
    if ($script:dimmed -eq $on) { return }
    $script:dimmed = $on
    $bgc = if ($on) { $colBgIdle } else { $colBg }
    $fgc = if ($on) { $colTextIdle } else { $colText }
    $win.Background = New-Object Windows.Media.SolidColorBrush $bgc
    $border.Background = New-Object Windows.Media.SolidColorBrush $bgc
    $label.Foreground = New-Object Windows.Media.SolidColorBrush $fgc
    if ($on) { $border.BorderBrush = New-Object Windows.Media.SolidColorBrush $colIdleEdge }
}

function Read-Status {
    # A malformed or half-written line is treated as "no news", never as an error.
    try {
        if (-not (Test-Path -LiteralPath $script:StatusPath)) { return $null }
        $raw = [System.IO.File]::ReadAllText($script:StatusPath, [System.Text.Encoding]::UTF8).Trim()
        if (-not $raw) { return $null }
        $parts = $raw.Split('|')
        if ($parts.Count -lt 4) { return $null }
        $stamp = 0L
        if (-not [long]::TryParse($parts[0], [ref]$stamp)) { return $null }
        if ($stamp -eq $script:lastSeenTicks) { return $null }
        return @{ stamp = $stamp; state = $parts[1]; step = $parts[2]; msg = ($parts[3..($parts.Count - 1)] -join '|') }
    }
    catch { return $null }
}

# ---- main loop --------------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
        if ($SessionFile -and ([DateTime]::UtcNow - $script:sessionCheckAt).TotalMilliseconds -ge 400) {
            $script:sessionCheckAt = [DateTime]::UtcNow
            if (-not (Test-CuSessionOwner $SessionFile $SessionId)) { $script:closing = $true; $win.Close(); return }
        }
        $script:tick++

        if (($script:tick -eq 3 -or $script:tick -eq 20) -and -not $NoCaptureExclude) {
            $ok = [CsNat]::SetWindowDisplayAffinity($script:wdaHwnd, [CsNat]::WDA_EXCLUDEFROMCAPTURE)
            Write-ChipLog ("tick={0} hwnd={1} first={2}/err={3} retry={4}/err={5}" -f `
                $script:tick, $script:wdaHwnd.ToInt64(), $script:wdaOk, $script:wdaErr, $ok, [CsNat]::LastError())
        }

        if (($script:tick % 3) -eq 0) {
            $s = Read-Status
            if ($s) {
                $script:lastSeenTicks = $s.stamp
                $script:lastWrite = [DateTime]::Now
                $script:state = $s.state
                $script:step = $s.step

                switch ($s.state) {
                    'busy' { Set-DotColor $colAccent; Start-Pulse }
                    'note' { Set-DotColor $colAccent; Start-Pulse }
                    'ok'   { Stop-Pulse 1.0; Set-DotColor $colOk }
                    'done' { Stop-Pulse 1.0; Set-DotColor $colOk }
                    'err'  { Stop-Pulse 1.0; Set-DotColor $colErr }
                    default { Stop-Pulse 1.0; Set-DotColor $colIdleEdge }
                }
                $isBad = ($s.state -eq 'err')
                $border.BorderBrush = New-Object Windows.Media.SolidColorBrush $(
                    if ($isBad) { $colErr } elseif ($s.state -eq 'ok' -or $s.state -eq 'done') { $colOk } else { $colAccent })
                $label.Text = $s.msg
                $stepText.Text = if ([int]$s.step -gt 0) { "step " + $s.step } else { "" }
                # Force the layout pass BEFORE re-clipping the region. With SizeToContent the
                # window is supposed to grow by itself, but measured here it kept the width it
                # had when the text was still the short startup placeholder, so longer messages
                # were silently cut off mid-character. UpdateLayout makes the resize happen now.
                $win.UpdateLayout()
                Update-Region
                Set-Position
            }
        }

        $idle = ([DateTime]::Now - $script:lastWrite).TotalSeconds
        Set-Dimmed ($idle -gt $IdleFadeSec)

        # Gone once the run is clearly over, and never left behind forever.
        $hideAfter = if ($script:state -eq 'done') { 8 } else { $IdleExitSec }
        if (-not $SessionFile -and $idle -gt $hideAfter) {
            $script:closing = $true
            $win.Close()
            return
        }

        if (($script:tick % 12) -eq 0) { Assert-Topmost }

        # Watchdog: the harness that owns this indicator must never leave it stranded.
        if ($WatchPid -gt 0 -and -not $script:closing -and ($script:tick % 25) -eq 0) {
            if (-not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) {
                $script:closing = $true
                $win.Close()
            }
        }
    })
$timer.Start()

$script:lastWrite = [DateTime]::Now
Set-DotColor $colAccent
Start-Pulse

[void]$win.ShowDialog()
$timer.Stop()
