@echo off
rem Wrapper: contractor delivery intake (deploy.ps1 -Delivery). Add -DeliveryUnattended for Task Scheduler.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Delivery %*
exit /b %ERRORLEVEL%
