@echo off
setlocal
rem Prefer PowerShell 7 (pwsh.exe); fall back to Windows PowerShell 5.1.
rem Hardcoding powershell.exe forced 5.1 even on machines that had 7 installed.
set "ROBO_PS=powershell.exe"
where /q pwsh.exe && set "ROBO_PS=pwsh.exe"
rem Print the host: which one ran is not recoverable from the logs otherwise.
echo [robo] powershell host: %ROBO_PS%
"%ROBO_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\robo.ps1" %*
exit /b %errorlevel%
