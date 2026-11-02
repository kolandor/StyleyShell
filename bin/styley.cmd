@echo off
rem styley - colour themes for Windows PowerShell and CMD. Works from both shells.
rem PowerShell resolves "styley" to this file too, so execution policy never blocks it.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\styley.ps1" %*
exit /b %ERRORLEVEL%
