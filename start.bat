@echo off
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0pet.ps1"
