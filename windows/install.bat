@echo off
REM install.bat - double-click launcher for setup.ps1
REM Runs the guided setup with the right execution policy, and requests
REM administrator rights (needed for the firewall rule).

REM Re-launch elevated if not already admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"

echo.
echo Done. You can close this window.
pause
