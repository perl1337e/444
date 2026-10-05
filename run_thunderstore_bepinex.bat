@echo off
title Thunderstore Mod Manager
cd /d "%~dp0"

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0workshop_downloader_thunderstore_bepinex.ps1"

if errorlevel 1 (
    echo.
    echo Launcher exited with an error.
    pause
)
