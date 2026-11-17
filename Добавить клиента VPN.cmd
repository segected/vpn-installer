@echo off
chcp 65001 >nul
title VPN Manager - Add client
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" -QuickAdd
if errorlevel 1 pause
