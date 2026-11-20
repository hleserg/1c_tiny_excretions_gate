@echo off
rem Wrapper: runs timeline.ps1 without changing the machine-wide execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0timeline.ps1" %*
exit /b %ERRORLEVEL%
