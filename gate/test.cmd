@echo off
rem Tests of the gate without 1C: fake 1cv8/1cv8c, every scenario in its own sandbox in %TEMP%.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test\tests.ps1" %*
exit /b %ERRORLEVEL%
