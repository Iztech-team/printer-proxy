@echo off
:: Baraka Printer Proxy — Windows Setup Launcher
:: This wrapper handles execution policy and admin elevation automatically.
:: Just double-click this file.

:: Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run the setup script with execution policy bypass
powershell -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"

pause
