@echo off
rem cu.cmd - wrapper so cu.ps1 runs without changing the machine execution policy.
rem Usage: cu.cmd <action> [args...]
setlocal
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cu.ps1" %*
exit /b %ERRORLEVEL%
