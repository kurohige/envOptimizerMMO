@echo off
:: Quick launcher for Gaming Mode - right-click > Run as Administrator
:: Usage: Run-GamingMode.bat           (Cloudflare DNS)
::        Run-GamingMode.bat -DNS google
::        Run-GamingMode.bat -SkipNetwork
::        Run-GamingMode.bat -Stop

echo.
echo   Starting Gaming Mode...
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: Requires Administrator privileges.
    echo Right-click and select "Run as administrator"
    pause
    exit /b 1
)

:: Use PowerShell 7 (pwsh.exe) — falls back to Windows PowerShell 5 if not installed
where pwsh.exe >nul 2>&1
if %errorLevel% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GamingMode.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GamingMode.ps1" %*
)

echo.
pause