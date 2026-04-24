@echo off
:: Quick launcher for Set-GameAffinity.ps1.
:: Right-click > Run as administrator.
::
:: Usage:
::   Run-GameAffinity.bat                                          BDO profile, attach mode
::   Run-GameAffinity.bat -ShowTopology                            Print topology only (no admin needed)
::   Run-GameAffinity.bat -LaunchGame "C:\...\BlackDesertLauncher.exe"   Launcher-inherit mode
::   Run-GameAffinity.bat -GameId BDO -DryRun                      See what would happen
::   Run-GameAffinity.bat -ProcessName notepad                     Ad-hoc against any process

echo.
echo   Starting Set-GameAffinity...
echo.

:: Admin check (only warns; the script itself handles unelevated -ShowTopology / -DryRun gracefully)
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo NOTE: Not running as administrator.
    echo       -ShowTopology and -DryRun will work without elevation.
    echo       Actual affinity application requires admin - re-run with "Run as administrator".
    echo.
)

where pwsh.exe >nul 2>&1
if %errorLevel% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-GameAffinity.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-GameAffinity.ps1" %*
)

echo.
pause
