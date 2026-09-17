@echo off
chcp 65001 >nul
title Селектор аудиторий для развертывания Renga

:: Проверка прав администратора
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"%~dp0GUI-Selector.ps1\"\"' -Verb RunAs"
    exit /b
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GUI-Selector.ps1"
