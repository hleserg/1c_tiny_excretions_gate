@echo off
rem Wrapper: runs nightly.ps1 (nightly gate run, -Install / -Uninstall / -Status).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nightly.ps1" %*
exit /b %ERRORLEVEL%
