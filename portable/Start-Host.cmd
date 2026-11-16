@echo off
REM ===================================================================
REM  Portable Remote Desktop - double-click launcher (no admin needed)
REM  Runs host.ps1 with the execution policy bypassed for THIS process
REM  only (a per-process bypass does not require administrator rights).
REM ===================================================================
setlocal

REM --- edit these defaults if you like ---
set PORT=8765
set FPS=12
set QUALITY=55
set SCALE=1.0
REM leave PASSWORD empty to auto-generate one at startup
set PASSWORD=

cd /d "%~dp0"

set ARGS=-Port %PORT% -Fps %FPS% -Quality %QUALITY% -Scale %SCALE%
if not "%PASSWORD%"=="" set ARGS=%ARGS% -Password %PASSWORD%

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0host.ps1" %ARGS%

echo.
pause
