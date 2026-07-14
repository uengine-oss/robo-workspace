@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\robo.ps1" %*
exit /b %errorlevel%

