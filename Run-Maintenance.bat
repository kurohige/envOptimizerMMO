@echo off
:: Quick launcher - right-click > Run as Administrator
:: Runs the maintenance script with a visible window

echo ==========================================
echo   WinOptimizer - Manual Maintenance Run
echo ==========================================
echo.

:: Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script requires Administrator privileges.
    echo Right-click and select "Run as administrator"
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinMaintenance.ps1"

echo.
echo ==========================================
echo   Done! Check the logs folder for details.
echo ==========================================
echo.
pause
