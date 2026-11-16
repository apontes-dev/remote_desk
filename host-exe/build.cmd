@echo off
REM ===================================================================
REM  Build RemoteDesktopHost.exe with the C# compiler that ships inside
REM  Windows (.NET Framework). No SDK, no admin, no NuGet.
REM ===================================================================
setlocal
cd /d "%~dp0"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo Could not find the in-box C# compiler (csc.exe).
  echo Expected under %%WINDIR%%\Microsoft.NET\Framework*\v4.0.30319\
  pause & exit /b 1
)

echo Using %CSC%
"%CSC%" /nologo /target:winexe /out:RemoteDesktopHost.exe /optimize+ ^
  /reference:System.dll ^
  /reference:System.Core.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Windows.Forms.dll ^
  /reference:System.Web.Extensions.dll ^
  RemoteDesktopHost.cs

if errorlevel 1 ( echo. & echo BUILD FAILED & pause & exit /b 1 )
echo.
echo Built RemoteDesktopHost.exe
echo.
pause
