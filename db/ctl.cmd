@echo off
rem Lanzador para Windows: ejecuta ctl.ps1 con ExecutionPolicy Bypass solo para este proceso.
rem No requiere Bash ni WSL. Uso: db\ctl.cmd up ^| status ^| apply ^| test ^| psql ^| reset ^| logs ^| down
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ctl.ps1" %*
exit /b %ERRORLEVEL%
