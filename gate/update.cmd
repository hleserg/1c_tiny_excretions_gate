@echo off
rem Gate update from GitHub releases (update.ps1).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %*
exit /b %ERRORLEVEL%
