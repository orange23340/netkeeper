@echo off
setlocal
cd /d "%~dp0"
set "P=%~dp0Diag.ps1"
if not exist "%P%" (
  echo [ERROR] Diag.ps1 not found next to this file.
  pause
  exit /b 1
)
fltmc >nul 2>&1
if not errorlevel 1 goto :run
echo Requesting administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%P%')"
if errorlevel 1 (
  echo.
  echo [ERROR] Elevation cancelled or failed.
  echo Tip: right-click this file and choose "Run as administrator".
  pause
)
exit /b
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%P%"
pause