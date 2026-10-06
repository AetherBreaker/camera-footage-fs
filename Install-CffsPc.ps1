<#
.SYNOPSIS
  Sets up cffs-pc: SFTPGo's config and firewall rules, then the WireGuard tunnel through
  wireguard-spoke-agent. Idempotent; re-run after every SFTPGo install or upgrade.

.DESCRIPTION
  Run from an administrator PowerShell:

    irm https://raw.githubusercontent.com/AetherBreaker/camera-footage-fs/main/Install-CffsPc.ps1 | iex

  or, with parameters:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AetherBreaker/camera-footage-fs/main/Install-CffsPc.ps1))) -Version v0.2.0 -PrivateKeyFile C:\path\cffs-pc.key

  It asks for the camera-footage-fs version (blank = the latest release) and downloads
  sftpgo.json from that tag; it never reads one from beside itself.

  1. SFTPGo: installs sftpgo.json over C:\ProgramData\SFTPGo\sftpgo.json (keeping a backup),
     removes the installer's "SFTPGo Service" rule (it allows sftpgo.exe in on every port,
     profile and address, and every SFTPGo install or upgrade re-creates it, hence the re-run),
     and replaces this script's rules (group "camera-footage-fs"):
     - 2022 (SFTP) and 8090 (web client) from the ingress spoke 10.8.0.23 only, on every
       profile because Windows classes the tunnel interface Public.
     - 8080 (admin) from -AdminRemoteAddress. With the default, LocalSubnet, the rule covers
       Domain and Private only, so never the Public tunnel interface; a LAN classed Public
       blocks admin rather than exposing it. An explicit address applies on every profile.
     Then restarts SFTPGo.
  2. WireGuard: creates C:\ProgramData\wireguard-spoke-agent (SYSTEM and Administrators only),
     installs WireGuard for Windows if missing, uv, and the agent; copies the private key in
     (deleting the source) and writes settings.env; stops the PC sleeping on AC power; then
     runs `wireguard-spoke-agent install`, which registers its task and brings the tunnel up.
#>
param(
  [string]$Version,
  [string]$PrivateKeyFile,
  [string[]]$AdminRemoteAddress = @('LocalSubnet'),
  [string]$PingKey,
  [string]$HeartbeatSlug,
  [string]$PushoverToken,
  [string]$PushoverUserKey
)

# A script block, so nothing but the parameters lands in the caller's session under `iex`;
# `return`/`throw`, never `exit`, which would close it.
& {
  $ErrorActionPreference = 'Stop'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator PowerShell.'  # #Requires is ignored under iex
  }

  $Repo = 'AetherBreaker/camera-footage-fs'
  $Peer = 'cffs-pc'
  $Ingress = '10.8.0.23'
  $Group = 'camera-footage-fs'
  $SftpgoDir = Join-Path $env:ProgramData 'SFTPGo'
  $AgentHome = Join-Path $env:ProgramData 'wireguard-spoke-agent'
  $AgentIndex = 'https://pypi.sweetfiretobacco.com/jacob.ogden/internal/+simple'
  $WireGuardExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'

  function Assert-Exit([string]$what) {
    # Native commands don't throw in Windows PowerShell; check each one that matters.
    if ($LASTEXITCODE -ne 0) { throw "$what failed with exit code $LASTEXITCODE" }
  }

  # ---- Version ----
  if (-not $Version) { $Version = Read-Host 'camera-footage-fs version to install (blank = latest)' }
  if (-not $Version) { $Version = (Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest").tag_name }
  Write-Host "Using camera-footage-fs $Version"

  # ---- 1. SFTPGo ----
  if (-not (Get-Service -Name 'SFTPGo' -ErrorAction SilentlyContinue)) { throw 'The SFTPGo service is not installed: install SFTPGo first.' }
  $config = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$Repo/$Version/sftpgo/sftpgo.json").Content
  $null = $config | ConvertFrom-Json  # refuse a malformed file before touching anything
  $target = Join-Path $SftpgoDir 'sftpgo.json'
  if (Test-Path $target) {
    $backup = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $target $backup
    Write-Host "Backed up the old SFTPGo config to $backup"
  }
  [IO.File]::WriteAllText($target, $config, [Text.UTF8Encoding]::new($false))
  Write-Host "Installed $target from $Version"

  $installerRule = Get-NetFirewallRule -DisplayName 'SFTPGo Service' -ErrorAction SilentlyContinue
  if ($installerRule) {
    $installerRule | Remove-NetFirewallRule
    Write-Host "Removed the SFTPGo installer's 'SFTPGo Service' rule"
  }
  Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -Group $Group -DisplayName 'SFTPGo SFTP + web client (cffs ingress)' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 2022, 8090 -RemoteAddress $Ingress -Profile Any | Out-Null
  $adminProfile = if ($AdminRemoteAddress -contains 'LocalSubnet') { 'Domain, Private' } else { 'Any' }
  New-NetFirewallRule -Group $Group -DisplayName 'SFTPGo admin' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 8080 -RemoteAddress $AdminRemoteAddress -Profile $adminProfile | Out-Null
  Write-Host "Firewall: 2022, 8090 from $Ingress (all profiles); 8080 from $($AdminRemoteAddress -join ', ') ($adminProfile)"
  $others = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { @($_.LocalPort | Where-Object { $_ -in '2022', '8080', '8090' }).Count } |
    Get-NetFirewallRule | Where-Object { $_.Group -ne $Group -and $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
  foreach ($r in $others) { Write-Warning "Another enabled inbound rule also opens one of these ports: '$($r.DisplayName)'" }

  Restart-Service -Name 'SFTPGo'
  Write-Host "Restarted SFTPGo; status: $((Get-Service -Name 'SFTPGo').Status)"

  # ---- 2. WireGuard, through wireguard-spoke-agent ----
  New-Item -ItemType Directory -Force (Join-Path $AgentHome 'logs') | Out-Null
  # Same lock-down SFTPGo's installer applies to its own folder: SYSTEM and Administrators, not inherited.
  icacls.exe $AgentHome /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
  Assert-Exit 'icacls'

  if (-not (Test-Path $WireGuardExe)) {
    $wgInstaller = Join-Path $env:TEMP 'wireguard-installer.exe'
    Invoke-WebRequest -UseBasicParsing 'https://download.wireguard.com/windows-client/wireguard-installer.exe' -OutFile $wgInstaller
    $sig = Get-AuthenticodeSignature $wgInstaller
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'WireGuard LLC') {
      throw "The downloaded WireGuard installer's signature is not a valid WireGuard LLC one ($($sig.Status))."
    }
    Start-Process -FilePath $wgInstaller -Wait
    if (-not (Test-Path $WireGuardExe)) { throw 'WireGuard for Windows did not install.' }
    Write-Host 'Installed WireGuard for Windows'
  }

  # Every uv path inside the locked folder, matching the agent's run.cmd.
  $env:UV_INSTALL_DIR = Join-Path $AgentHome 'uv'
  $env:UV_NO_MODIFY_PATH = '1'
  $env:UV_PYTHON_INSTALL_DIR = Join-Path $AgentHome 'python'
  $env:UV_TOOL_DIR = Join-Path $AgentHome 'tools'
  $env:UV_TOOL_BIN_DIR = Join-Path $AgentHome 'bin'
  $env:UV_CACHE_DIR = Join-Path $AgentHome 'cache'
  $env:UV_MANAGED_PYTHON = '1'
  $uv = Join-Path $env:UV_INSTALL_DIR 'uv.exe'
  if (-not (Test-Path $uv)) { Invoke-RestMethod 'https://astral.sh/uv/install.ps1' | Invoke-Expression }
  & $uv tool install --upgrade --index $AgentIndex wireguard-spoke-agent
  Assert-Exit 'uv tool install wireguard-spoke-agent'

  $keyTarget = Join-Path $AgentHome "$Peer.key"
  if (-not $PrivateKeyFile -and -not (Test-Path $keyTarget)) {
    Write-Host "Select $Peer.key in the file picker"
    try {
      Add-Type -AssemblyName System.Windows.Forms
      $dialog = [Windows.Forms.OpenFileDialog]@{ Title = "Select $Peer.key"; Filter = 'WireGuard key (*.key)|*.key|All files (*.*)|*.*' }
      # A topmost owner keeps the picker from opening behind the console.
      $owner = [Windows.Forms.Form]@{ TopMost = $true }
      if ($dialog.ShowDialog($owner) -eq 'OK') { $PrivateKeyFile = $dialog.FileName }
      $owner.Dispose()
    } catch {
      # No desktop session, or an MTA host (PowerShell 7) where the dialog can't open.
      Write-Warning "The file picker could not open: $($_.Exception.Message)"
    }
    if (-not $PrivateKeyFile) { $PrivateKeyFile = Read-Host "Path to $Peer.key" }
    if (-not $PrivateKeyFile) { throw "No $Peer.key given." }
  }
  if ($PrivateKeyFile) {
    # Copy then delete, not move: a moved file keeps its old ACL instead of the locked folder's.
    Copy-Item $PrivateKeyFile $keyTarget -Force
    Remove-Item $PrivateKeyFile -Force
    Write-Host "Installed $keyTarget and deleted $PrivateKeyFile"
  }

  # settings.env: keep existing values, override with any given, always set the fixed ones.
  $settingsFile = Join-Path $AgentHome 'settings.env'
  $settings = [ordered]@{}
  if (Test-Path $settingsFile) {
    foreach ($line in Get-Content $settingsFile) {
      if ($line.Trim() -and -not $line.TrimStart().StartsWith('#')) {
        $k, $v = $line -split '=', 2
        $settings[$k.Trim()] = $v.Trim()
      }
    }
  }
  $settings['WG_PEER_NAME'] = $Peer
  $settings['PERSISTED_DIR_LOC'] = $AgentHome
  # Until aeth-ext treats a missing password as "email off": its settings require one, and
  # ALERTS_RECIPIENTS=[] keeps it from ever logging in to the real mailbox with the placeholder.
  $settings['ALERTS_EMAIL_PWD'] = 'unused'
  $settings['ALERTS_RECIPIENTS'] = '[]'
  if ($PingKey) { $settings['PINGKEY'] = $PingKey }
  if ($HeartbeatSlug) { $settings['HEARTBEAT_SLUG'] = $HeartbeatSlug }
  if ($PushoverToken) { $settings['ALERTS_PUSHOVER_TOKEN'] = $PushoverToken }
  if ($PushoverUserKey) { $settings['ALERTS_PUSHOVER_USER_KEY'] = $PushoverUserKey }
  $text = ($settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n"
  [IO.File]::WriteAllText($settingsFile, "$text`r`n", [Text.UTF8Encoding]::new($false))
  Write-Host "Wrote $settingsFile"

  powercfg.exe /change standby-timeout-ac 0
  Assert-Exit 'powercfg'

  & (Join-Path $env:UV_TOOL_BIN_DIR 'wireguard-spoke-agent.exe') install
  Assert-Exit 'wireguard-spoke-agent install'
  Write-Host "Done. The agent's log is $(Join-Path $AgentHome 'logs\agent.log')."
}
