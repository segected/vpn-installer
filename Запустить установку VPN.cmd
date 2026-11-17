@echo off
chcp 65001 >nul
setlocal
title VPN - install and manage
where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo Не найден powershell.exe. Включите Windows PowerShell.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0menu.ps1" %*
if errorlevel 1 pause
exit /b %ERRORLEVEL%
