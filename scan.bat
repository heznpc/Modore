@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -NoProfile -Command "& '%~dp0scripts\menu.ps1'"
pause