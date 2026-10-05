#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Applies this repo's SFTPGo config and firewall rules to cffs-pc. Idempotent; re-run after
  every SFTPGo install or upgrade.

.DESCRIPTION
  1. Copies sftpgo.json (beside this script) over C:\ProgramData\SFTPGo\sftpgo.json, keeping a
     timestamped backup of the old file.
  2. Removes the installer's "SFTPGo Service" rule: it allows sftpgo.exe inbound on every port,
     profile and address, and would override the rules below. Every SFTPGo install or upgrade
     re-creates it, hence the re-run.
  3. Replaces this script's own rules (group "camera-footage-fs"):
     - 2022 (SFTP) and 8090 (web client) from the ingress spoke 10.8.0.23 only, on every profile
       because Windows classes the tunnel interface Public.
     - 8080 (admin) from -AdminRemoteAddress. With the default, LocalSubnet, the rule covers the
       Domain and Private profiles only, so it never applies to the Public tunnel interface; if
       the office LAN is classed Public too, admin is blocked, not exposed. An explicit address
       (e.g. your device's Tailscale IP) applies on every profile, the address being the guard.
  4. Restarts the SFTPGo service.

.EXAMPLE
  .\Apply-CffsConfig.ps1
.EXAMPLE
  .\Apply-CffsConfig.ps1 -AdminRemoteAddress 100.101.102.103
#>
param(
  [string[]]$AdminRemoteAddress = @('LocalSubnet')
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'SFTPGo'
$ConfigDir = Join-Path $env:ProgramData 'SFTPGo'
$Source = Join-Path $PSScriptRoot 'sftpgo.json'
$Group = 'camera-footage-fs'
$Ingress = '10.8.0.23'

if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { throw "Service '$ServiceName' not found: install SFTPGo first." }
if (-not (Test-Path $ConfigDir)) { throw "$ConfigDir not found: install SFTPGo first." }
if (-not (Test-Path $Source)) { throw "$Source not found: run this script from the repo's sftpgo folder." }
$null = Get-Content $Source -Raw | ConvertFrom-Json  # refuse a malformed file before touching anything

# 1. Config
$Target = Join-Path $ConfigDir 'sftpgo.json'
if (Test-Path $Target) {
  $Backup = "$Target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item $Target $Backup
  Write-Host "Backed up the old config to $Backup"
}
Copy-Item $Source $Target -Force
Write-Host "Installed $Target"

# 2. The installer's catch-all rule
$installerRule = Get-NetFirewallRule -DisplayName 'SFTPGo Service' -ErrorAction SilentlyContinue
if ($installerRule) {
  $installerRule | Remove-NetFirewallRule
  Write-Host "Removed the installer's 'SFTPGo Service' rule"
}

# 3. Our rules, replaced whole
Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Group $Group -DisplayName 'SFTPGo SFTP + web client (cffs ingress)' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 2022, 8090 -RemoteAddress $Ingress -Profile Any | Out-Null
$adminProfile = if ($AdminRemoteAddress -contains 'LocalSubnet') { 'Domain, Private' } else { 'Any' }
New-NetFirewallRule -Group $Group -DisplayName 'SFTPGo admin' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8080 -RemoteAddress $AdminRemoteAddress -Profile $adminProfile | Out-Null
Write-Host "Firewall: 2022, 8090 from $Ingress (all profiles); 8080 from $($AdminRemoteAddress -join ', ') ($adminProfile)"

# Anything else still letting traffic in to these ports is worth knowing about.
$others = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { @($_.LocalPort | Where-Object { $_ -in '2022', '8080', '8090' }).Count } |
  Get-NetFirewallRule | Where-Object { $_.Group -ne $Group -and $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
foreach ($r in $others) { Write-Warning "Another enabled inbound rule also opens one of these ports: '$($r.DisplayName)'" }

# 4. Restart
Restart-Service -Name $ServiceName
Write-Host "Restarted $ServiceName; status: $((Get-Service -Name $ServiceName).Status)"
