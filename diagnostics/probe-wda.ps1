# Isolate whether SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) can work here at all,
# and whether WPF's AllowsTransparency (i.e. a layered window) is what breaks it.
# Writes a plain-text report, because a hidden GUI process has nowhere to print.
param([string]$Out = "$env:TEMP\wda-probe.txt")

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not ('WdaNat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WdaNat {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    public const uint WDA_NONE = 0x0;
    public const uint WDA_MONITOR = 0x1;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    public static int LastError() { return Marshal.GetLastWin32Error(); }
}
'@
}

$report = New-Object System.Collections.ArrayList
function Say($t) { [void]$report.Add($t) }

function Try-Affinity([string]$label, [bool]$transparent) {
    $w = New-Object Windows.Window
    $w.WindowStyle = [Windows.WindowStyle]::None
    $w.AllowsTransparency = $transparent
    $w.Background = if ($transparent) { [Windows.Media.Brushes]::Transparent }
                    else { New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(255, 20, 40, 60)) }
    $w.Topmost = $true
    $w.ShowInTaskbar = $false
    $w.ShowActivated = $false
    $w.Width = 200; $w.Height = 40
    $w.Left = 400; $w.Top = 400
    $w.Content = New-Object Windows.Controls.TextBlock -Property @{ Text = $label; Foreground = [Windows.Media.Brushes]::White }

    $script:handle = [IntPtr]::Zero
    $script:earlyOk = $false
    $script:earlyErr = 0
    $w.Add_SourceInitialized({
            $helper = New-Object Windows.Interop.WindowInteropHelper($w)
            $script:handle = $helper.Handle
            $script:earlyOk = [WdaNat]::SetWindowDisplayAffinity($script:handle, [WdaNat]::WDA_EXCLUDEFROMCAPTURE)
            $script:earlyErr = [WdaNat]::LastError()
        })
    $w.Add_Loaded({
            $w.Dispatcher.InvokeAsync({
                    Start-Sleep -Milliseconds 900
                    $lateOk = [WdaNat]::SetWindowDisplayAffinity($script:handle, [WdaNat]::WDA_EXCLUDEFROMCAPTURE)
                    $lateErr = [WdaNat]::LastError()
                    $monOk = [WdaNat]::SetWindowDisplayAffinity($script:handle, [WdaNat]::WDA_MONITOR)
                    $monErr = [WdaNat]::LastError()
                    $ex = [WdaNat]::GetWindowLong($script:handle, -20)
                    Say ("{0}: layered={1} hwnd={2} early={3}(err {4}) late={5}(err {6}) monitor={7}(err {8}) exStyle=0x{9:X}" -f `
                        $label, ([bool]($ex -band 0x80000)), $script:handle.ToInt64(), `
                        $script:earlyOk, $script:earlyErr, $lateOk, $lateErr, $monOk, $monErr, $ex)
                    # put it back to EXCLUDE for the capture test
                    [void][WdaNat]::SetWindowDisplayAffinity($script:handle, [WdaNat]::WDA_EXCLUDEFROMCAPTURE)
                }) | Out-Null
        })
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(2600)
    $t.Add_Tick({ $t.Stop(); $w.Close() })
    $t.Start()
    [void]$w.ShowDialog()
}

Try-Affinity "plain" $false
Try-Affinity "transparent" $true

Say ("os=" + [Environment]::OSVersion.VersionString)
[System.IO.File]::WriteAllText($Out, ($report -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
