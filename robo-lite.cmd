@echo off
setlocal
rem lite 판 굽기. 공용 `robo.cmd release` 와 **별개 줄기**다 —
rem 공용 release 경로는 enterprise 앱 모양(이미지 열 개)에 맞춰져 있고,
rem lite 앱은 일곱 서비스다. 자세한 이유는 scripts\robo-lite.ps1 머리말에.
rem
rem ⚠ `.env` 에 ROBO_RELEASE_VARIANT 를 주어야 한다(예: lite). 비우면
rem    enterprise 판과 같은 릴리스 id 가 나와 폴더와 도커 태그를 덮어쓴다.
set "ROBO_PS=powershell.exe"
where /q pwsh.exe && set "ROBO_PS=pwsh.exe"
echo [robo-lite] powershell host: %ROBO_PS%
"%ROBO_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\robo-lite.ps1" %*
exit /b %errorlevel%
