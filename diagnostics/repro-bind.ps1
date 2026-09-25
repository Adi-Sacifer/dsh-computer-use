# Minimal repro of the binding failure seen in cu.ps1's `wake` action.
function Invoke-AccessibilityWake([IntPtr]$h, [int]$budgetMs) {
    Write-Output ("  entered h={0} budget={1}" -f $h, $budgetMs)
    return New-Object psobject -Property @{ answered = 2; before = 0; after = 0; waitedMs = 1043 }
}

Write-Output "--- case A: positional ---"
$h = [IntPtr]133060
$WakeMs = 2500
$w = Invoke-AccessibilityWake $h $WakeMs
Write-Output ("  w type={0} answered={1}" -f $w.GetType().Name, $w.answered)

Write-Output "--- case B: named params ---"
$w2 = Invoke-AccessibilityWake -h $h -budgetMs ([int]$WakeMs)
Write-Output ("  w2 type={0} answered={1}" -f $w2.GetType().Name, $w2.answered)

Write-Output "--- case C: int h, like the real script ---"
$h3 = 133060
$w3 = Invoke-AccessibilityWake $h3 $WakeMs
Write-Output ("  w3 type={0} answered={1}" -f $w3.GetType().Name, $w3.answered)

Write-Output "--- case D: does 'wake' collide with anything? ---"
Write-Output ("  get-command Invoke-AccessibilityWake -> {0}" -f (Get-Command Invoke-AccessibilityWake -ErrorAction SilentlyContinue).CommandType)
