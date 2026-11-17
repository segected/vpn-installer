@echo off
chcp 65001 >nul
title VPN Manager - Add AmneziaWG client
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" -QuickAwg
if errorlevel 1 pause
