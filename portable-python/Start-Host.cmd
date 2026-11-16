@echo off
REM ===================================================================
REM  Portable Remote Desktop (Python) - double-click launcher.
REM  No install, no admin. Finds a Python to run rdhost.py with, in
REM  this order:
REM     1) a bundled .\python\python.exe  (the embeddable build)
REM     2) the 'py' launcher, if present
REM     3) python / python3 on PATH
REM  If none is found, run Get-PortablePython.ps1 first (it downloads
REM  the official embeddable Python into .\python - no admin needed).
REM ===================================================================
setlocal
cd /d "%~dp0"

REM --- edit these defaults if you like ---
set PORT=8765
set FPS=12
set QUALITY=55
set SCALE=1.0
set PASSWORD=
REM e.g.  set PASSWORD=hunter2    (leave empty to auto-generate)

set ARGS=--port %PORT% --fps %FPS% --quality %QUALITY% --scale %SCALE%
if not "%PASSWORD%"=="" set ARGS=%ARGS% --password %PASSWORD%

set PY=
if exist "%~dp0python\python.exe" set PY="%~dp0python\python.exe"
if not defined PY ( where py >nul 2>nul && set PY=py )
if not defined PY ( where python >nul 2>nul && set PY=python )
if not defined PY ( where python3 >nul 2>nul && set PY=python3 )

if not defined PY (
  echo No Python found.
  echo Run this first ^(no admin needed^):
  echo     powershell -ExecutionPolicy Bypass -File Get-PortablePython.ps1
  echo.
  pause
  exit /b 1
)

%PY% "%~dp0rdhost.py" %ARGS%

echo.
pause
