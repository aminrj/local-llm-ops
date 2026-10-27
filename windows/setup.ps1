<#
.SYNOPSIS
  Windows side of the ai-desktop for the personal assistant. Check by default; -Apply changes things.

.DESCRIPTION
  Run in an elevated PowerShell (Run as administrator), from this repo's folder in WSL:
    powershell.exe -ExecutionPolicy Bypass -File windows\setup.ps1            # check only
    powershell.exe -ExecutionPolicy Bypass -File windows\setup.ps1 -Apply     # apply
    ... -Apply -Wol    # also prepare wake-on-LAN over the powerline adapter (later step)

  What -Apply does:
    1. Lets TCP 8443 in from OPNsense's house address only (192.168.0.2), in both the
       Hyper-V firewall (WSL mirrored networking) and Windows Defender Firewall.
    2. Keeps the PC awake on mains power (no sleep, no hibernate) until wake-on-LAN works.
    3. Keeps the WSL VM alive when no terminal is open (.wslconfig vmIdleTimeout=-1)
       and starts WSL at logon (scheduled task), so the arbiter and the proxy run.
  With -Wol:
    4. The Ethernet adapter (powerline) carries no IP traffic: IPv4/IPv6 unbound, so
       Wi-Fi stays the only network. The NIC itself still listens for magic packets.
    5. Wake on Magic Packet on, Fast Startup off (it breaks wake from shutdown).
    Prints the Ethernet MAC for homelab-foundation's inventory (house.ai_desktop_eth_mac).

  It also reports whether your desk llama servers (8081-8083, no API key) are reachable
  from the house network. They should not be; -Apply -BlockInbound closes that (opt-in,
  because a client on another machine may rely on it today).
#>
param(
  [switch]$Apply,
  [switch]$Wol,
  [switch]$BlockInbound,
  [string]$OpnsenseWan = "192.168.0.2",
  [int]$Port = 8443,
  [string]$Distro = ""
)
$ErrorActionPreference = "Stop"
$WslVmCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"   # fixed id of WSL in the Hyper-V firewall
$RuleName = "LLM-Agent-TLS-from-OPNsense"

function Say($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  ok: $m" -ForegroundColor Green }
function Would($m) { Write-Host "  would: $m" -ForegroundColor Yellow }
function Warn($m) { Write-Host "  WARNING: $m" -ForegroundColor Red }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this in an elevated PowerShell (Run as administrator)." }

# ---------- WSL networking ----------
Say "WSL networking mode"
$wslconfig = Join-Path $env:USERPROFILE ".wslconfig"
$cfg = if (Test-Path $wslconfig) { Get-Content $wslconfig -Raw } else { "" }
if ($cfg -match "(?im)^\s*networkingMode\s*=\s*mirrored") { Ok "mirrored (WSL listeners share the Windows addresses)" }
else { Warn "not mirrored: the rule below covers mirrored mode; in NAT mode :8443 in WSL is not reachable from the LAN at all. homelab-foundation CLAUDE.md says this machine uses mirrored mode: check $wslconfig." }

Say "Hyper-V firewall default for WSL (inbound)"
try {
  $hv = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $WslVmCreatorId
  if ($hv.DefaultInboundAction -eq "Allow") {
    Warn "inbound is ALLOWED by default: your desk llama servers on 0.0.0.0:8081-8083 (no API key) are reachable from the house Wi-Fi."
    if ($Apply -and $BlockInbound) {
      Set-NetFirewallHyperVVMSetting -Name $WslVmCreatorId -DefaultInboundAction Block
      Ok "default inbound for WSL set to Block"
    } else { Would "with -BlockInbound: set the WSL default inbound action to Block (check first that nothing, e.g. your Mac over Tailscale, uses 8081-8083 from outside)" }
  } else { Ok "default inbound: $($hv.DefaultInboundAction)" }
} catch { Warn "could not read the Hyper-V firewall settings ($($_.Exception.Message)); older Windows build?" }

# ---------- :8443 from OPNsense only ----------
Say "TCP $Port from $OpnsenseWan only"
$hvRule = Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue
if ($hvRule) { Ok "Hyper-V rule $RuleName exists" }
elseif ($Apply) {
  New-NetFirewallHyperVRule -Name $RuleName -DisplayName "LLM agent TLS from OPNsense" -Direction Inbound `
    -VMCreatorId $WslVmCreatorId -Protocol TCP -LocalPorts $Port -RemoteAddresses $OpnsenseWan -Action Allow | Out-Null
  Ok "Hyper-V rule $RuleName created"
} else { Would "create Hyper-V firewall rule $RuleName (TCP $Port from $OpnsenseWan)" }

$fwRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
if ($fwRule) { Ok "Windows Defender rule $RuleName exists" }
elseif ($Apply) {
  New-NetFirewallRule -Name $RuleName -DisplayName "LLM agent TLS from OPNsense" -Direction Inbound -Protocol TCP `
    -LocalPort $Port -RemoteAddress $OpnsenseWan -Action Allow -Profile Any | Out-Null
  Ok "Windows Defender rule $RuleName created"
} else { Would "create Windows Defender rule $RuleName (TCP $Port from $OpnsenseWan)" }

# ---------- stay awake for now ----------
Say "Power: stay awake on mains power (until wake-on-LAN works)"
if ($Apply) {
  powercfg /change standby-timeout-ac 0 | Out-Null
  powercfg /change hibernate-timeout-ac 0 | Out-Null
  Ok "sleep and hibernate off on AC"
} else { Would "powercfg /change standby-timeout-ac 0; hibernate-timeout-ac 0" }

# ---------- WSL stays up ----------
Say "WSL stays up without a terminal"
if ($cfg -match "(?im)^\s*vmIdleTimeout\s*=\s*-1") { Ok ".wslconfig vmIdleTimeout=-1" }
elseif ($Apply) {
  if (Test-Path $wslconfig) { Copy-Item $wslconfig "$wslconfig.bak-$(Get-Date -Format yyyyMMddHHmmss)" }
  if ($cfg -match "(?im)^\s*\[wsl2\]") { $cfg = $cfg -replace "(?im)^(\s*\[wsl2\]\s*)$", "`$1`r`nvmIdleTimeout=-1" }
  else { $cfg = $cfg.TrimEnd() + "`r`n`r`n[wsl2]`r`nvmIdleTimeout=-1`r`n" }
  Set-Content -Path $wslconfig -Value $cfg -Encoding ascii
  Ok "added vmIdleTimeout=-1 (takes effect after 'wsl --shutdown')"
} else { Would "add vmIdleTimeout=-1 under [wsl2] in $wslconfig" }

$task = Get-ScheduledTask -TaskName "WSL autostart (llm agent)" -ErrorAction SilentlyContinue
if ($task) { Ok "scheduled task 'WSL autostart (llm agent)' exists" }
elseif ($Apply) {
  $wslArgs = if ($Distro) { "-d $Distro --exec /bin/true" } else { "--exec /bin/true" }
  $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument $wslArgs
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  Register-ScheduledTask -TaskName "WSL autostart (llm agent)" -Action $action -Trigger $trigger `
    -Description "Boots WSL at logon so systemd starts llm-arbiter and llm-agent-proxy (local-llm-ops)." | Out-Null
  Ok "scheduled task created (at logon of $env:USERNAME). After a reboot, someone must sign in, or turn on automatic sign-in."
} else { Would "register a logon task that runs 'wsl.exe --exec /bin/true'" }

# ---------- wake-on-LAN over powerline (later) ----------
if ($Wol) {
  Say "Wake-on-LAN over the powerline adapter"
  $eth = Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq "802.3" -and $_.InterfaceDescription -notmatch "Wi-?Fi|Wireless|802\.11" } | Select-Object -First 1
  if (-not $eth) { throw "no wired Ethernet adapter found" }
  Ok "Ethernet adapter: $($eth.Name) ($($eth.InterfaceDescription)), MAC $($eth.MacAddress), link $($eth.Status)"
  foreach ($c in "ms_tcpip", "ms_tcpip6") {
    $b = Get-NetAdapterBinding -Name $eth.Name -ComponentID $c
    if (-not $b.Enabled) { Ok "$c unbound" }
    elseif ($Apply) { Disable-NetAdapterBinding -Name $eth.Name -ComponentID $c; Ok "$c unbound (Wi-Fi stays the only network)" }
    else { Would "unbind $c from $($eth.Name)" }
  }
  foreach ($p in "Wake on Magic Packet", "Shutdown Wake-On-Lan", "Wake on magic packet when system is in the S0ix power state") {
    $prop = Get-NetAdapterAdvancedProperty -Name $eth.Name -DisplayName $p -ErrorAction SilentlyContinue
    if (-not $prop) { continue }
    if ($prop.DisplayValue -eq "Enabled") { Ok "$p enabled" }
    elseif ($Apply) { Set-NetAdapterAdvancedProperty -Name $eth.Name -DisplayName $p -DisplayValue "Enabled"; Ok "$p enabled" }
    else { Would "enable '$p'" }
  }
  if ($Apply) {
    Set-NetAdapterPowerManagement -Name $eth.Name -WakeOnMagicPacket Enabled -ErrorAction SilentlyContinue
    powercfg /deviceenablewake "$($eth.InterfaceDescription)" 2>$null | Out-Null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -Value 0
    Ok "magic packet wake armed; Fast Startup off"
  } else { Would "arm the adapter for magic-packet wake and turn Fast Startup off" }
  Write-Host "`n  Put this in homelab-foundation inventory/network.yml: house.ai_desktop_eth_mac: $($eth.MacAddress -replace '-', ':')"
  Write-Host "  BIOS (by hand): Wake on LAN / Power on by PCI-E = Enabled, ErP = Disabled."
}

if (-not $Apply) { Write-Host "`nNothing was changed. To apply: add -Apply" -ForegroundColor Yellow }
