@echo off
rem fxkill.cmd - emergency kill switch for the takeover overlay AND the activity chip.
rem Double-click this to remove the fog and the chip immediately, with no harness and no agent
rem needed. Nothing here depends on the DSH process still being alive.
setlocal enabledelayedexpansion
set "N=0"
for /f "usebackq tokens=*" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'fx\.ps1|cu-status\.ps1' } | ForEach-Object { $_.ProcessId }"`) do (
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
