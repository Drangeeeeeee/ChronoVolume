@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT=%SCRIPT_DIR%ChronoVolumePrototypeSetupAssistant.ps1"

if not exist "%SCRIPT%" (
  echo Cannot find ChronoVolumePrototypeSetupAssistant.ps1
  echo Expected: "%SCRIPT%"
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File "%SCRIPT%"

if errorlevel 1 (
  echo.
  echo The setup assistant closed with an error.
  pause
)
