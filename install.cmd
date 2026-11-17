@echo off
rem Gate installer: copies ci to the install folder, asks first settings, adds it to PATH.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
