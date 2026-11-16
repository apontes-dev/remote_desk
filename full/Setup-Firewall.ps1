<#
.SYNOPSIS
    Add (or remove) a Windows Firewall inbound rule for the full server port.
    REQUIRES ADMINISTRATOR - this is the one step that needs elevation, which is
    why it lives in the "full" (full-access machine) version only.

.EXAMPLE
    # allow inbound TCP 8766 (run from an elevated PowerShell)
    powershell -ExecutionPolicy Bypass -File Setup-Firewall.ps1 -Port 8766

.EXAMPLE
    # remove the rule again
    powershell -ExecutionPolicy Bypass -File Setup-Firewall.ps1 -Port 8766 -Remove
#>
param(
    [int]$Port = 8766,
    [switch]$Remove
)

$ruleName = "RemoteDesktop-Full-$Port"

$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then run it again." -ForegroundColor Yellow
    exit 1
}

if ($Remove) {
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    Write-Host "Removed firewall rule '$ruleName' (if it existed)." -ForegroundColor Green
    exit 0
}

if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Write-Host "Rule '$ruleName' already exists." -ForegroundColor Yellow
    exit 0
}

New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -Profile Private,Domain | Out-Null

Write-Host "Added inbound TCP rule for port $Port (Private + Domain profiles)." -ForegroundColor Green
Write-Host "To remove later:  Setup-Firewall.ps1 -Port $Port -Remove" -ForegroundColor Gray
