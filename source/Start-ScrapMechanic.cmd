@echo off
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bootstrapper.ps1" -EnableDevAchievements
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bootstrapper.ps1" -EnableDevAchievements -GameCommand %*
)
if errorlevel 1 pause
