@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bootstrapper.ps1"
if errorlevel 1 pause
