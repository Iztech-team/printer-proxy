@echo off
:: Baraka Printer Proxy -- Windows Setup Launcher
:: Launches the GUI wizard without showing a console window.

:: Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -WindowStyle Hidden -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Launch PowerShell hidden (no console window behind the GUI)
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
