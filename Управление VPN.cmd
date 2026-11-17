@echo off
chcp 65001 >nul
title VPN Manager
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1"
if errorlevel 1 pause
