@echo off
setlocal

set "SCRIPT_DIR=%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    start "" pwsh -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ItalianTranslator.ps1"
    exit /b 0
)

where powershell >nul 2>nul
if %errorlevel%==0 (
    start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ItalianTranslator.ps1"
    exit /b 0
)

echo PowerShell non trovato.
exit /b 1
