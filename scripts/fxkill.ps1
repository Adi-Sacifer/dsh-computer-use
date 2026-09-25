# Emergency stop: close the current session and precisely matched pre-v2 helpers.
$ErrorActionPreference = 'Stop'
$SessionOwnerPid = 0
. (Join-Path $PSScriptRoot 'cu-session.ps1')
Stop-CuSession
$helperPattern = '-File\s+"?' + [regex]::Escape($PSScriptRoot) + '[\\/](fx|cu-status)\.ps1(?:"|\s|$)'
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe' OR Name='pwsh-preview.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $helperPattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
