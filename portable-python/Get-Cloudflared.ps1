<#
.SYNOPSIS
    Download cloudflared.exe next to this script so the "Internet" access mode
    works. No installation, no admin: cloudflared is a single portable binary
    and a quick tunnel is OUTBOUND only (no router/port-forward, no firewall
    rule, no Cloudflare account needed).

.DESCRIPTION
    The Internet toggle in the control panel runs:
        cloudflared tunnel --url http://localhost:<port>
    which returns a public https://<random>.trycloudflare.com address that
    anyone can open in a browser (they still need the access password).

.PARAMETER Arch
    amd64 (default) or 386, to match the target machine.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-Cloudflared.ps1
#>
param(
    [ValidateSet("amd64", "386")][string]$Arch = "amd64"
)

$ErrorActionPreference = "Stop"
$dest = Join-Path $PSScriptRoot "cloudflared.exe"
if (Test-Path $dest) {
    Write-Host "cloudflared.exe already present." -ForegroundColor Green
    exit 0
}

$url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$Arch.exe"
Write-Host "Downloading cloudflared from:" -ForegroundColor Cyan
Write-Host "  $url"
Write-Host "(about 25-70 MB, single file, no install)`n" -ForegroundColor Gray

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

if (Test-Path $dest) {
    $mb = "{0:N1}" -f ((Get-Item $dest).Length / 1MB)
    Write-Host "Done. Saved cloudflared.exe ($mb MB)." -ForegroundColor Green
    Write-Host "Now start the host and switch the control panel to Internet mode." -ForegroundColor Green
} else {
    Write-Host "Download failed." -ForegroundColor Red
    exit 1
}
