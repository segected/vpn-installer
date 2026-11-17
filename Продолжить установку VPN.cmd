@echo off
chcp 65001 >nul
setlocal
title VPN Installer - Resume
where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo Не найден powershell.exe. Нужен Windows PowerShell.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" -Resume %*
exit /b %ERRORLEVEL%
