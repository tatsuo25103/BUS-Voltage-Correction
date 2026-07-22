@echo off
cd /d "%~dp0"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0BUS_voltage_correction_desktop_test_V0.7.ps1"
