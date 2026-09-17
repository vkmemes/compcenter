@echo off
chcp 65001 >nul
title Установка и обновление Renga Professional

:: Проверка прав администратора
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Запрос прав Администратора...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

echo ========================================================
echo   Запуск процесса обновления Renga Professional...
echo ========================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Renga.ps1"

if %errorlevel% neq 0 (
    echo.
    echo [ОШИБКА] Произошла ошибка во время установки.
    pause
) else (
    echo.
    echo [УСПЕХ] Обновление Renga успешно завершено.
    timeout /t 5 >nul
)
