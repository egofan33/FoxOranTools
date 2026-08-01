@echo off
setlocal

:: Main entry: invoke the PowerShell colored menu script.
:: -OutputFormat Text prevents PowerShell from emitting CLIXML (garbled output).
powershell -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -File "%~dp0Menu.ps1"

endlocal
exit /b %ERRORLEVEL%
