@echo off
rem Uninstalls styley: restores the original console colours, removes it from PATH and disk.
rem Options: -KeepColors (keep both themes), -KeepColorsFor powershell|cmd (keep that shell's theme),
rem          -Purge (also delete %LOCALAPPDATA%\styley).
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
exit /b %ERRORLEVEL%
