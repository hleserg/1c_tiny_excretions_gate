@echo off
rem Gate settings editor (config.psd1).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0settings.ps1" %*
exit /b %ERRORLEVEL%
