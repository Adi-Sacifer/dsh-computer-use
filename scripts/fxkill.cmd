@echo off
rem fxkill.cmd - emergency kill switch for the takeover overlay AND the activity chip.
rem
rem Double-click this to remove the fog and the chip immediately, with no host application and
rem no agent needed. Nothing here depends on the host process still being alive.
rem
rem WHY IT MATCHES SO NARROWLY
rem The processes are found by scanning command lines, and a loose match is a footgun: the tool
rem that looks for "fx.ps1" is itself a PowerShell process, so a bare filename match can kill the
rem shell that launched it if that shell's command line happens to mention the script. Both
rem helpers are launched as `powershell ... -File "...\fx.ps1" ...`, so requiring `-File` and a
rem path separator before the name keeps the match on real instances only.
setlocal enabledelayedexpansion
set "N=0"
for /f "usebackq tokens=*" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match '-File.*[\\/]fx\.ps1|-File.*[\\/]cu-status\.ps1' } | ForEach-Object { $_.ProcessId }"`) do (
  echo Killing overlay/chip process %%P
  taskkill /PID %%P /F >nul 2>&1
  set /a N+=1
)
if "!N!"=="0" (
  echo No takeover overlay or activity chip is running.
) else (
  echo Done. Overlay/chip processes killed: !N!
)
del /q "%TEMP%\cu-fx.pid" >nul 2>&1
del /q "%TEMP%\cu-fx.mute" >nul 2>&1
del /q "%TEMP%\cu-status.pid" >nul 2>&1
rem linger a moment so a double-clicked window stays readable
ping -n 4 127.0.0.1 >nul
