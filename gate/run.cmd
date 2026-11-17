@echo off
rem Wrapper: runs run.ps1 without changing the machine-wide execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
exit /b %ERRORLEVEL%
