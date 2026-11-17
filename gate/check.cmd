@echo off
rem Wrapper: runs check.ps1 without changing the machine-wide execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check.ps1" %*
exit /b %ERRORLEVEL%
