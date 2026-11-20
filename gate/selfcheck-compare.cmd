@echo off
rem Wrapper: runs selfcheck-compare.ps1 without changing the machine-wide execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0selfcheck-compare.ps1" %*
exit /b %ERRORLEVEL%
