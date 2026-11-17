@echo off
rem Wrapper: runs deploy.ps1 without changing the machine-wide execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
exit /b %ERRORLEVEL%
