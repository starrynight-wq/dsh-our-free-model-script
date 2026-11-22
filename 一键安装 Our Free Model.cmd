@echo off
chcp 65001 >nul
setlocal EnableExtensions
title Our Free Model - Install

set "SCRIPT=%~dp0install-our-free-model.ps1"
if not exist "%SCRIPT%" (
    echo.
    echo [ERROR] install-our-free-model.ps1 was not found next to this .cmd file.
    echo         Keep all files of this folder together and try again.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" echo [FAILED] Exit code %CODE% - read the messages above.
if "%CODE%"=="0" echo [DONE] You can close this window.
echo Press any key to close this window . . .
pause >nul
exit /b %CODE%
