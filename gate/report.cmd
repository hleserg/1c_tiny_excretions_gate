@echo off
rem Wrapper: runs report.ps1 without changing the machine-wide execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0report.ps1" %*
exit /b %ERRORLEVEL%
