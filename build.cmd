@echo off
rem Build: go run ./src/build. Example: build.cmd -private ..\1c_tiny_excretions_gate-agb
pushd "%~dp0src\build"
go run . -root ..\.. %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%
