@echo off

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0Bootstrapper.ps1" ^
  -EnableDevAchievements

if errorlevel 1 (
    pause
    exit /b 1
)

%*