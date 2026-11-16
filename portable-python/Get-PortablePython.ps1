<#
.SYNOPSIS
    Download the official Windows *embeddable* Python into .\python so the host
    can run with no installation and no administrator rights.

.DESCRIPTION
    The embeddable package is a plain .zip (python.exe + the standard library).
    It is not "installed": nothing touches the registry, Program Files, or PATH,
    so no admin is required. rdhost.py uses only the standard library + ctypes,
    all of which the embeddable build includes, so no pip / packages are needed.

    All network access here is OUTBOUND to python.org, which never requires a
    firewall change or admin rights.

.PARAMETER Version
    Python version to fetch (default 3.12.8).

.PARAMETER Arch
    amd64 (default) or win32, to match the target machine.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-PortablePython.ps1
#>
param(
    [string]$Version = "3.12.8",
    [ValidateSet("amd64", "win32")][string]$Arch = "amd64"
)

$ErrorActionPreference = "Stop"
$dest = Join-Path $PSScriptRoot "python"
if (Test-Path (Join-Path $dest "python.exe")) {
    Write-Host "Embeddable Python already present in .\python" -ForegroundColor Green
    exit 0
}

$zipName = "python-$Version-embed-$Arch.zip"
$url = "https://www.python.org/ftp/python/$Version/$zipName"
$tmp = Join-Path $env:TEMP $zipName

Write-Host "Downloading $url ..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

Write-Host "Extracting to $dest ..." -ForegroundColor Cyan
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
Expand-Archive -Path $tmp -DestinationPath $dest -Force
Remove-Item $tmp -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $dest "python.exe")) {
    Write-Host ""
    Write-Host "Done. Portable Python is in .\python" -ForegroundColor Green
    Write-Host "Now just run Start-Host.cmd" -ForegroundColor Green
} else {
    Write-Host "Something went wrong - python.exe not found after extraction." -ForegroundColor Red
    exit 1
}
