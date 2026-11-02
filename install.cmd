@echo off
rem Installs styley for the current user. Pass -Dev, -Uninstall or -Purge through.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
