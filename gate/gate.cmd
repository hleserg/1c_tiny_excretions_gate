@echo off
rem Short name for the gate: same as run.cmd, for use from PATH.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
exit /b %ERRORLEVEL%
