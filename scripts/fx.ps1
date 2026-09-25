# fx.ps1 - "DaFeiYu takes over" screen overlay.
#
# Full-screen, borderless, always-on-top, CLICK-THROUGH WPF overlay:
#   * black fog creeping in from all four screen edges, alive (drifts + breathes)
#   * a glowing headline at the top
# It never steals focus and never blocks the mouse, so the agent can keep working
# underneath it. Launched detached by cu.ps1 (fxon / fxoff).
#
# Lifetime: the overlay is meant to live for the whole takeover, so -DurationSec defaults to
# 24 h - i.e. it is bounded by fxoff or by the watchdog, not by the clock. The clock stays
# only as a last-resort backstop so a crash can never leave the screen covered.

[CmdletBinding()]
param(
    [int]$DurationSec = 86400,
    [string]$TextFile = "",
    # Direct headline override, so a caller can set the words without inventing a file. The file
    # stays the default path (it is the only way to keep the headline inside an ASCII-only
    # script); this exists because `fxon -Text "..."` used to accept a headline and silently
    # ignore it - measured: the flag arrived, nothing changed on screen.
    [string]$Text = "",
    [string]$SubTextFile = "",
    [string]$Font = "Source Han Serif SC Heavy",
    [string]$SubFont = "",
    [string]$Accent = "#3FA9F5",
    [int]$Seed = 20260925,
    [string]$MuteFile = "",
    [double]$Dim = 0.10,
    [double]$DimAfterSec = 6,
    [int]$WatchPid = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# This script is deliberately ASCII-only: Windows PowerShell 5.1 reads BOM-less
# UTF-8 as the ANSI codepage, which corrupts non-ASCII source and breaks parsing.
# The headline lives in a UTF-8 text file and is decoded explicitly instead.
# Order matters: an explicit -Text wins over the file, and the file wins over the built-in default.
if ([string]::IsNullOrWhiteSpace($TextFile)) { $TextFile = Join-Path $PSScriptRoot 'fx-text.txt' }
if ([string]::IsNullOrWhiteSpace($Text) -and (Test-Path -LiteralPath $TextFile)) {
    $Text = [System.IO.File]::ReadAllText($TextFile, [System.Text.Encoding]::UTF8).Trim()
}
if ([string]::IsNullOrWhiteSpace($Text)) { $Text = "DaFeiYu is taking over" }

# Historical note: cu.ps1's `shot` used to touch a mute file for the duration of a capture so
# the fog never darkened a screenshot of the screen edges. That made the overlay visibly blink
# out and back on every screenshot, which is worse than the fog it avoided: the effect is now
# steady and always present, and the capture keeps it. Clear any stale flag at startup.
$script:MutePath = if ([string]::IsNullOrWhiteSpace($MuteFile)) { Join-Path $env:TEMP 'cu-fx.mute' } else { $MuteFile }
Remove-Item -LiteralPath $script:MutePath -Force -ErrorAction SilentlyContinue

# Optional blackletter Latin subtitle. A real Fraktur face carries no CJK glyphs, so the
# gothic flavour rides on a Latin line while the headline itself stays readable Chinese.
$Sub = ""
if ([string]::IsNullOrWhiteSpace($SubTextFile)) { $SubTextFile = Join-Path $PSScriptRoot 'fx-subtext.txt' }
if (Test-Path -LiteralPath $SubTextFile) {
    $Sub = [System.IO.File]::ReadAllText($SubTextFile, [System.Text.Encoding]::UTF8).Trim()
}
if ([string]::IsNullOrWhiteSpace($SubFont)) {
    # Preference order: a real Fraktur first, then the gothic-flavoured display face.
    # WPF can use a font straight from disk: file URI + #FamilyName, no installation.
    $subCandidates = @(
        @{ File = 'fonts\UnifrakturCook-Bold.ttf'; Family = 'UnifrakturCook' },
        @{ File = 'fonts\UnifrakturMaguntia-Book.ttf'; Family = 'UnifrakturMaguntia' },
        @{ File = 'fonts\GrenzeGotisch.ttf'; Family = 'Grenze Gotisch Black' }
    )
    foreach ($cand in $subCandidates) {
        $p = Join-Path $PSScriptRoot $cand.File
        if (Test-Path -LiteralPath $p) {
            $SubFont = 'file:///' + ($p -replace '\\', '/') + '#' + $cand.Family
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($SubFont)) { $SubFont = 'Georgia' }
}

if (-not ('FxNat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FxNat {
    [DllImport("user32.dll", SetLastError = true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
'@
}

$rnd = New-Object System.Random($Seed)

# ---- geometry (DIPs; WPF maps these onto the physical screen) ----------------
$vx = [Windows.SystemParameters]::VirtualScreenLeft
$vy = [Windows.SystemParameters]::VirtualScreenTop
$vw = [Windows.SystemParameters]::VirtualScreenWidth
$vh = [Windows.SystemParameters]::VirtualScreenHeight

function New-FogBrush([double]$core) {
    $b = New-Object Windows.Media.RadialGradientBrush
    $b.GradientOrigin = New-Object Windows.Point(0.5, 0.5)
    $b.Center = New-Object Windows.Point(0.5, 0.5)
    $b.RadiusX = 0.5
    $b.RadiusY = 0.5
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb([byte](255 * $core), 0, 0, 0), 0.0)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb([byte](170 * $core), 0, 0, 0), 0.35)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb([byte](40 * $core), 0, 0, 0), 0.65)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 0, 0, 0), 1.0)))
    return $b
}

# ---- visuals ----------------------------------------------------------------
$root = New-Object Windows.Controls.Grid
$root.Background = [Windows.Media.Brushes]::Transparent

$fog = New-Object Windows.Controls.Canvas
$fog.Opacity = 0
[void]$root.Children.Add($fog)

$script:blobs = @()

function Add-Blob([double]$cx, [double]$cy, [double]$size, [double]$core) {
    $e = New-Object Windows.Shapes.Ellipse
    $sx = 1.0 + $rnd.NextDouble() * 0.55
    $sy = 1.0 + $rnd.NextDouble() * 0.55
    $e.Width = $size
    $e.Height = $size
    $e.Fill = New-FogBrush $core
    $e.Opacity = 0
    $tg = New-Object Windows.Media.TransformGroup
    $tg.Children.Add((New-Object Windows.Media.ScaleTransform($sx, $sy)))
    $tg.Children.Add((New-Object Windows.Media.RotateTransform(($rnd.NextDouble() * 360))))
    $e.RenderTransform = $tg
    $e.RenderTransformOrigin = New-Object Windows.Point(0.5, 0.5)
    [Windows.Controls.Canvas]::SetLeft($e, ($cx - $size / 2))
    [Windows.Controls.Canvas]::SetTop($e, ($cy - $size / 2))
    [void]$fog.Children.Add($e)

    $script:blobs += [pscustomobject]@{
        Shape      = $e
        X          = $cx - $size / 2
        Y          = $cy - $size / 2
        Base       = 0.45 + $rnd.NextDouble() * 0.5
        Phase      = $rnd.NextDouble() * 6.283
        Speed      = 0.35 + $rnd.NextDouble() * 0.7
        DriftSpeed = 0.06 + $rnd.NextDouble() * 0.12
        DriftAmp   = 14 + $rnd.NextDouble() * 34
        Delay      = $rnd.NextDouble() * 1.1
    }
}

# A straight dark band guarantees a solid black border; the blobs add organic
# texture on top of it. Kept shallow so the middle of the screen stays clean and
# readable - this overlay must not blind the agent that is working underneath it.
function Add-EdgeBand([string]$side, [double]$thick, [byte]$alpha) {
    $r = New-Object Windows.Shapes.Rectangle
    $b = New-Object Windows.Media.LinearGradientBrush
    switch ($side) {
        'top' { $b.StartPoint = New-Object Windows.Point(0, 0); $b.EndPoint = New-Object Windows.Point(0, 1) }
        'bottom' { $b.StartPoint = New-Object Windows.Point(0, 1); $b.EndPoint = New-Object Windows.Point(0, 0) }
        'left' { $b.StartPoint = New-Object Windows.Point(0, 0); $b.EndPoint = New-Object Windows.Point(1, 0) }
        'right' { $b.StartPoint = New-Object Windows.Point(1, 0); $b.EndPoint = New-Object Windows.Point(0, 0) }
    }
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb($alpha, 0, 0, 0), 0.0)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb([byte]($alpha * 0.5), 0, 0, 0), 0.45)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 0, 0, 0), 1.0)))
    $r.Fill = $b
    if ($side -eq 'top' -or $side -eq 'bottom') {
        $r.Width = $vw
        $r.Height = $thick
        [Windows.Controls.Canvas]::SetLeft($r, 0)
        [Windows.Controls.Canvas]::SetTop($r, $(if ($side -eq 'top') { 0 } else { $vh - $thick }))
    }
    else {
        $r.Width = $thick
        $r.Height = $vh
        [Windows.Controls.Canvas]::SetTop($r, 0)
        [Windows.Controls.Canvas]::SetLeft($r, $(if ($side -eq 'left') { 0 } else { $vw - $thick }))
    }
    [void]$fog.Children.Add($r)
}

# Soft dark halo behind the title block. The shallow edge fog alone does not reach far
# enough down, so over a light app the subtitle washed out; this guarantees contrast
# for the headline without darkening the middle of the screen.
$halo = New-Object Windows.Shapes.Ellipse
$halo.Width = $vw * 1.15
$halo.Height = $vh * 0.62
$hb = New-Object Windows.Media.RadialGradientBrush
$hb.Center = New-Object Windows.Point(0.5, 0.5)
$hb.GradientOrigin = New-Object Windows.Point(0.5, 0.35)
$hb.RadiusX = 0.5
$hb.RadiusY = 0.5
$hb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(225, 0, 0, 0), 0.0)))
$hb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(175, 0, 0, 0), 0.42)))
$hb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(70, 0, 0, 0), 0.70)))
$hb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 0, 0, 0), 1.0)))
$halo.Fill = $hb
[Windows.Controls.Canvas]::SetLeft($halo, ($vw * 0.5 - $halo.Width / 2))
[Windows.Controls.Canvas]::SetTop($halo, (-$vh * 0.16))
[void]$fog.Children.Add($halo)

Add-EdgeBand 'top' ($vh * 0.17) 235
Add-EdgeBand 'bottom' ($vh * 0.17) 235
Add-EdgeBand 'left' ($vw * 0.10) 225
Add-EdgeBand 'right' ($vw * 0.10) 225

# top + bottom blobs
$szTB = $vh * 0.40
$n = 12
for ($i = 0; $i -lt $n; $i++) {
    $x = $vw * (($i + 0.5) / $n) + ($rnd.NextDouble() - 0.5) * ($vw / $n)
    Add-Blob $x ($vy + $vh * 0.010) $szTB (0.55 + $rnd.NextDouble() * 0.45)
    Add-Blob ($x + ($rnd.NextDouble() - 0.5) * 90) ($vy + $vh * 0.990) $szTB (0.50 + $rnd.NextDouble() * 0.45)
}
# left + right blobs
$szLR = $vw * 0.20
$m = 9
for ($i = 0; $i -lt $m; $i++) {
    $y = $vh * (($i + 0.5) / $m)
    Add-Blob ($vx + $vw * 0.006) ($vy + $y) $szLR (0.55 + $rnd.NextDouble() * 0.45)
    Add-Blob ($vx + $vw * 0.994) ($vy + $y) $szLR (0.50 + $rnd.NextDouble() * 0.45)
}

# ---- headline ---------------------------------------------------------------
$head = New-Object Windows.Controls.StackPanel
$head.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
$head.VerticalAlignment = [Windows.VerticalAlignment]::Top
$head.Margin = New-Object Windows.Thickness(0, ($vh * 0.055), 0, 0)

$fs = [Math]::Max(36, [Math]::Min(78, $vh * 0.056))

# WPF renders a single Effect per element and does not render EffectGroup, so use
# one cyan glow (the fog behind the headline is already near-black, giving contrast).
$glow = New-Object Windows.Media.Effects.DropShadowEffect
$glow.Color = [Windows.Media.ColorConverter]::ConvertFromString($Accent)
$glow.BlurRadius = 34
$glow.ShadowDepth = 0
$glow.Opacity = 1.0
# Vertical gradient fill: white at the top falling to pale cyan at the baseline. That
# shading is what gives a serif headline its printed-poster weight.
$textBrush = New-Object Windows.Media.LinearGradientBrush
$textBrush.StartPoint = New-Object Windows.Point(0, 0)
$textBrush.EndPoint = New-Object Windows.Point(0, 1)
$textBrush.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(255, 255, 255, 255), 0.0)))
$textBrush.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(255, 222, 243, 255), 0.55)))
$textBrush.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(255, 148, 208, 255), 1.0)))

# One TextBlock per character: WPF has no letter-spacing property, and per-character
# blocks give both the wide poster tracking and a staggered reveal for free.
$row = New-Object Windows.Controls.StackPanel
$row.Orientation = [Windows.Controls.Orientation]::Horizontal
$row.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
$gap = [Math]::Round($fs * 0.13, 1)
$ci = 0
foreach ($ch in $Text.ToCharArray()) {
    $cb = New-Object Windows.Controls.TextBlock
    $cb.Text = [string]$ch
    $cb.FontFamily = New-Object Windows.Media.FontFamily($Font)
    $cb.FontSize = $fs
    $cb.FontWeight = [Windows.FontWeights]::Bold
    $cb.Foreground = $textBrush
    $cb.Margin = New-Object Windows.Thickness($gap, 0, $gap, 0)
    $cb.Effect = $glow
    $cb.Opacity = 0
    $ca = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(760)))
    $ca.BeginTime = [TimeSpan]::FromMilliseconds(360 + $ci * 95)
    $ca.EasingFunction = New-Object Windows.Media.Animation.CubicEase
    $ca.EasingFunction.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
    $cb.BeginAnimation([Windows.UIElement]::OpacityProperty, $ca)
    [void]$row.Children.Add($cb)
    $ci++
}

$rule = New-Object Windows.Shapes.Rectangle
$rule.Height = 2.5
$rule.Width = [Math]::Min(880, $vw * 0.42)
$rule.Margin = New-Object Windows.Thickness(0, 16, 0, 0)
$rule.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
$rgb = New-Object Windows.Media.LinearGradientBrush
$rgb.StartPoint = New-Object Windows.Point(0, 0.5)
$rgb.EndPoint = New-Object Windows.Point(1, 0.5)
$ac = [Windows.Media.ColorConverter]::ConvertFromString($Accent)
$rgb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, $ac.R, $ac.G, $ac.B), 0.0)))
$rgb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(230, $ac.R, $ac.G, $ac.B), 0.5)))
$rgb.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, $ac.R, $ac.G, $ac.B), 1.0)))
$rule.Fill = $rgb

[void]$head.Children.Add($row)
[void]$head.Children.Add($rule)
if (-not [string]::IsNullOrWhiteSpace($Sub)) {
    $sb = New-Object Windows.Controls.TextBlock
    # WPF has no letter-spacing, so widen the blackletter line by spacing the glyphs.
    $sb.Text = (($Sub.ToCharArray() | ForEach-Object { [string]$_ }) -join ' ')
    $sb.FontFamily = New-Object Windows.Media.FontFamily($SubFont)
    $sb.FontSize = [Math]::Max(16, $fs * 0.44)
    $sb.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(252, 226, 245, 255))
    $sb.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $sb.Margin = New-Object Windows.Thickness(0, 12, 0, 0)
    $sb.Opacity = 0
    $sa = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(1100)))
    $sa.BeginTime = [TimeSpan]::FromMilliseconds(1300)
    $sa.EasingFunction = New-Object Windows.Media.Animation.CubicEase
    $sa.EasingFunction.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
    $sb.BeginAnimation([Windows.UIElement]::OpacityProperty, $sa)
    [void]$head.Children.Add($sb)
}
[void]$root.Children.Add($head)

$tt = New-Object Windows.Media.TranslateTransform(0, -26)
$head.RenderTransform = $tt
$head.Opacity = 1

# ---- window -----------------------------------------------------------------
$win = New-Object Windows.Window
$win.WindowStyle = [Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background = [Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.IsHitTestVisible = $false
$win.ResizeMode = [Windows.ResizeMode]::NoResize
$win.Left = $vx
$win.Top = $vy
$win.Width = $vw
$win.Height = $vh
$win.Content = $root

$win.Add_SourceInitialized({
        $helper = New-Object Windows.Interop.WindowInteropHelper($win)
        $h = $helper.Handle
        $ex = [FxNat]::GetWindowLong($h, -20)
        # WS_EX_LAYERED | WS_EX_TRANSPARENT (click-through) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
        [void][FxNat]::SetWindowLong($h, -20, ($ex -bor 0x80000 -bor 0x20 -bor 0x08000000 -bor 0x80))
    })

# intro animations
$fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.6)))
$fadeIn.EasingFunction = New-Object Windows.Media.Animation.CubicEase
$fadeIn.EasingFunction.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
$fog.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)

# The headline fades in per character (see $row above), so no head-level fade here.

$slide = New-Object Windows.Media.Animation.DoubleAnimation(-26.0, 0.0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(1500)))
$slide.BeginTime = [TimeSpan]::FromMilliseconds(320)
$slide.EasingFunction = New-Object Windows.Media.Animation.CubicEase
$slide.EasingFunction.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
$tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)

$pulse = New-Object Windows.Media.Animation.DoubleAnimation(20.0, 46.0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(1700)))
$pulse.AutoReverse = $true
$pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$glow.BeginAnimation([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, $pulse)

# ---- living fog + lifetime --------------------------------------------------
$script:t0 = [DateTime]::Now
$script:closing = $false
$script:muted = $false
$script:opacityTarget = 1.0
$script:watchTick = 0

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(40)
$timer.Add_Tick({
        $el = ([DateTime]::Now - $script:t0).TotalSeconds
        foreach ($b in $script:blobs) {
            $birth = [Math]::Max(0.0, [Math]::Min(1.0, ($el - $b.Delay) / 1.2))
            $o = $b.Base * $birth * (0.70 + 0.30 * [Math]::Sin($el * $b.Speed + $b.Phase))
            $b.Shape.Opacity = [Math]::Max(0.0, [Math]::Min(1.0, $o))
            $dx = [Math]::Sin($el * $b.DriftSpeed + $b.Phase) * $b.DriftAmp
            $dy = [Math]::Cos($el * $b.DriftSpeed * 0.73 + $b.Phase) * $b.DriftAmp * 0.6
            [Windows.Controls.Canvas]::SetLeft($b.Shape, ($b.X + $dx))
            [Windows.Controls.Canvas]::SetTop($b.Shape, ($b.Y + $dy))
        }

        # Watchdog: if the process that owns this takeover has exited, take the overlay down too.
        # A closed harness must never leave fog on the screen with nobody left able to dismiss it.
        if ($WatchPid -gt 0 -and -not $script:closing) {
            $script:watchTick++
            if ($script:watchTick % 20 -eq 0) {
                if (-not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) {
                    $script:closing = $true
                    $bye = New-Object Windows.Media.Animation.DoubleAnimation($script:opacityTarget, 0.0, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(700)))
                    $bye.Add_Completed({ $win.Close() })
                    $root.BeginAnimation([Windows.UIElement]::OpacityProperty, $bye)
                }
            }
        }

        # Ambient mode: full strength for the intro, then settle to $Dim and STAY there, so the
        # user can see at a glance that the machine is being driven. Nothing may change this
        # while the run lasts - a capture in particular must not interrupt it (it used to blink
        # the overlay off, and that flash was far more disruptive than the fog it avoided).
        # $Dim is 0.10 because that is where the ambient fog stops costing anything: measured
        # against an overlay-off baseline on this desktop (dark wallpaper), the edge-corner
        # probe reads 87.7 -> 79.8 (-9%) and the top-title probe 139.3 -> 127.2 (-9%), while a
        # white window area drops only 255 -> 249 (-2.4%). At the old 0.25 those were -22% and
        # -23%, which is exactly the "the effect is in my screenshot" cost we wanted to avoid.
        if (-not $script:closing) {
            $target = $Dim
            if ($el -lt $DimAfterSec) { $target = 1.0 }
            if ([Math]::Abs($target - $script:opacityTarget) -gt 0.001) {
                $script:opacityTarget = $target
                $ta = New-Object Windows.Media.Animation.DoubleAnimation($target, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(700)))
                $ta.EasingFunction = New-Object Windows.Media.Animation.CubicEase
                $ta.EasingFunction.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
                $root.BeginAnimation([Windows.UIElement]::OpacityProperty, $ta)
            }
        }

        if (-not $script:closing -and $el -gt $DurationSec) {
            $script:closing = $true
            $out = New-Object Windows.Media.Animation.DoubleAnimation($script:opacityTarget, 0.0, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.1)))
            $out.Add_Completed({ $win.Close() })
            $root.BeginAnimation([Windows.UIElement]::OpacityProperty, $out)
        }
    })
$timer.Start()

[void]$win.ShowDialog()
