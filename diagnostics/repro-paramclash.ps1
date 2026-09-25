# Hypothesis: assigning a non-int to a variable whose name matches a typed script
# PARAMETER (PowerShell variables are case-insensitive, so $w IS $W) raises a
# MetadataError attributed to the enclosing script - which is the confusing error seen in
# cu.ps1's `wake` action.
[CmdletBinding()]
param(
    [int]$W = 0,
    [int]$H = 0
)

Write-Output "--- A: assign an object to `$w (== `$W, an [int] parameter) ---"
try {
    $w = New-Object psobject -Property @{ a = 1 }
    Write-Output ("  no error; w={0} type={1}" -f $w, $w.GetType().Name)
}
catch {
    Write-Output ("  THREW: {0}" -f $_.Exception.Message)
    Write-Output ("  category: {0}" -f $_.CategoryInfo.GetType().Name)
}

Write-Output "--- B: same thing under a name that is not a parameter ---"
try {
    $report = New-Object psobject -Property @{ a = 1 }
    Write-Output ("  no error; report type={0}" -f $report.GetType().Name)
}
catch {
    Write-Output ("  THREW: {0}" -f $_.Exception.Message)
}

Write-Output "--- C: is `$w really `$W? ---"
Write-Output ("  (Get-Variable W).Value type = {0}" -f (Get-Variable -Name W).Value.GetType().Name)
