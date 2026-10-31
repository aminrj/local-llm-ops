<#
.SYNOPSIS
  Windows side of the ai-desktop for the personal assistant. Check by default; -Apply changes things.

.DESCRIPTION
  Run in an elevated PowerShell (Run as administrator), from this repo's folder in WSL:
    powershell.exe -ExecutionPolicy Bypass -File windows\setup.ps1            # check only
    powershell.exe -ExecutionPolicy Bypass -File windows\setup.ps1 -Apply     # apply
    ... -Apply -Wol    # also prepare wake-on-LAN over the powerline adapter (later step)
    ... -Apply -AtBoot # start WSL at boot, without anyone signing in (asks for your password once)
    ... -Apply -RemoteShutdown   # let sshd in WSL (port 2222) in from the tailnet only

  What -Apply does:
    1. Lets TCP 8743 in from OPNsense's house address only (192.168.0.2), in both the
       Hyper-V firewall (WSL mirrored networking) and Windows Defender Firewall.
    2. Keeps the PC awake on mains power (no sleep, no hibernate) until wake-on-LAN works.
    3. Keeps the WSL VM alive when no terminal is open (.wslconfig vmIdleTimeout=-1)
       and starts WSL at logon (scheduled task), so the arbiter and the proxy run.
  With -Wol:
    4. The Ethernet adapter (powerline) carries no IP traffic: IPv4/IPv6 unbound, so
       Wi-Fi stays the only network. The NIC itself still listens for magic packets.
    5. Wake on Magic Packet on, Fast Startup off (it breaks wake from shutdown).
    Prints the Ethernet MAC for homelab-foundation's inventory (wake_on_lan.mac).
  With -AtBoot:
    6. The WSL task starts at boot instead of at logon, "whether the user is logged on or not",
       and runs a session that never ends (sleep infinity), so after a wake-on-LAN systemd runs
       the arbiter and the proxy without anyone signing in. No 72-hour run limit.
  With -RemoteShutdown:
    7. TCP 2222 (sshd in WSL, scripts/agent-setup.sh) in from the tailnet (100.64.0.0/10) only.
  Also turn on Tailscale's "Run unattended" (tray icon, Settings) so the tailnet is up before sign-in.

  It also reports whether your desk llama servers (8081-8083, no API key) are reachable
  from the house network. They should not be; -Apply -BlockInbound closes that (opt-in,
  because a client on another machine may rely on it today).
#>
param(
  [switch]$Apply,
  [switch]$Wol,
  [switch]$BlockInbound,
  [switch]$AtBoot,
  [switch]$RemoteShutdown,
  [string]$Tailnet = "100.64.0.0/10",
  [string]$OpnsenseWan = "192.168.0.2",
  [int]$Port = 8743,
  [string]$Distro = ""
)
$ErrorActionPreference = "Stop"
$WslVmCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"   # fixed id of WSL in the Hyper-V firewall
# The port is in the name: a Hyper-V rule can't be changed or removed once created (Windows answers
# "Access is denied" even elevated, seen 2026-10-28), so a new port means a new rule.
$RuleName = "LLM-Agent-TLS-$Port-from-OPNsense"
$OldRuleNames = @("LLM-Agent-TLS-from-OPNsense")   # 8443, before k3d took that port

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
else { Warn "not mirrored: the rule below covers mirrored mode; in NAT mode :8743 in WSL is not reachable from the LAN at all. homelab-foundation CLAUDE.md says this machine uses mirrored mode: check $wslconfig." }

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

# ---------- :8743 from OPNsense only (not 8443: k3d's load balancer uses it) ----------
Say "TCP $Port from $OpnsenseWan only"
if (Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue) { Ok "Hyper-V rule $RuleName exists" }
elseif ($Apply) {
  New-NetFirewallHyperVRule -Name $RuleName -DisplayName "LLM agent TLS $Port from OPNsense" -Direction Inbound `
    -VMCreatorId $WslVmCreatorId -Protocol TCP -LocalPorts $Port -RemoteAddresses $OpnsenseWan -Action Allow | Out-Null
  Ok "Hyper-V rule $RuleName created"
} else { Would "create Hyper-V firewall rule $RuleName (TCP $Port from $OpnsenseWan)" }

if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) { Ok "Windows Defender rule $RuleName exists" }
elseif ($Apply) {
  New-NetFirewallRule -Name $RuleName -DisplayName "LLM agent TLS $Port from OPNsense" -Direction Inbound -Protocol TCP `
    -LocalPort $Port -RemoteAddress $OpnsenseWan -Action Allow -Profile Any | Out-Null
  Ok "Windows Defender rule $RuleName created"
} else { Would "create Windows Defender rule $RuleName (TCP $Port from $OpnsenseWan)" }

# Rules for an old port: removed when Windows lets us, otherwise left (OPNsense only lets the lab
# reach the current port, so an old allow rule opens nothing the lab can use).
foreach ($old in $OldRuleNames) {
  if (Get-NetFirewallRule -Name $old -ErrorAction SilentlyContinue) {
    if ($Apply) { Remove-NetFirewallRule -Name $old; Ok "Windows Defender rule $old removed" }
    else { Would "remove Windows Defender rule $old" }
  }
  if (Get-NetFirewallHyperVRule -Name $old -ErrorAction SilentlyContinue) {
    if ($Apply) {
      try { Remove-NetFirewallHyperVRule -Name $old -ErrorAction Stop; Ok "Hyper-V rule $old removed" }
      catch {
        try { Disable-NetFirewallHyperVRule -Name $old -ErrorAction Stop; Warn "Hyper-V rule $old could not be removed; disabled instead" }
        catch { Warn "Hyper-V rule $old can't be removed or disabled ($($_.Exception.Message)); harmless: OPNsense only allows the lab to reach $Port" }
      }
    } else { Would "remove Hyper-V rule $old (or disable it, or warn)" }
  }
}

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

$TaskName = "WSL autostart (llm agent)"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$atBootNow = $task -and ($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskBootTrigger" })
if ($AtBoot) {
  if ($atBootNow) { Ok "scheduled task '$TaskName' starts at boot" }
  elseif ($Apply) {
    $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Your Windows password: the task runs WSL at boot, before anyone signs in"
    if ($task) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    $keep = 'exec sleep infinity'
    $wslArgs = if ($Distro) { "-d $Distro --exec /bin/sh -c `"$keep`"" } else { "--exec /bin/sh -c `"$keep`"" }
    $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument $wslArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
      -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
      -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Limited `
      -Description "Boots WSL at startup (no sign-in needed) and keeps it up, so systemd runs llm-arbiter and llm-agent-proxy (local-llm-ops)." | Out-Null
    Ok "task '$TaskName' now starts WSL at boot and keeps it running (test: reboot without signing in)"
  } else { Would "re-register '$TaskName': at startup, whether logged on or not, 'wsl.exe --exec sh -c ""exec sleep infinity""', no time limit (asks for your password)" }
}
elseif ($task) { Ok "scheduled task '$TaskName' exists$(if ($atBootNow) { ' (at boot)' } else { ' (at logon; -AtBoot starts it without sign-in)' })" }
elseif ($Apply) {
  $wslArgs = if ($Distro) { "-d $Distro --exec /bin/true" } else { "--exec /bin/true" }
  $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument $wslArgs
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  Register-ScheduledTask -TaskName "WSL autostart (llm agent)" -Action $action -Trigger $trigger `
    -Description "Boots WSL at logon so systemd starts llm-arbiter and llm-agent-proxy (local-llm-ops)." | Out-Null
  Ok "scheduled task created (at logon of $env:USERNAME). After a reboot, someone must sign in, or turn on automatic sign-in."
} else { Would "register a logon task that runs 'wsl.exe --exec /bin/true'" }

# ---------- remote shutdown: sshd in WSL on 2222, from the tailnet only ----------
if ($RemoteShutdown) {
  Say "TCP 2222 (sshd in WSL) from the tailnet $Tailnet only"
  $SshRule = "WSL-SSH-2222-from-tailnet"
  if (Get-NetFirewallHyperVRule -Name $SshRule -ErrorAction SilentlyContinue) { Ok "Hyper-V rule $SshRule exists" }
  elseif ($Apply) {
    New-NetFirewallHyperVRule -Name $SshRule -DisplayName "WSL sshd 2222 from the tailnet" -Direction Inbound `
      -VMCreatorId $WslVmCreatorId -Protocol TCP -LocalPorts 2222 -RemoteAddresses $Tailnet -Action Allow | Out-Null
    Ok "Hyper-V rule $SshRule created"
  } else { Would "create Hyper-V firewall rule $SshRule (TCP 2222 from $Tailnet)" }
  if (Get-NetFirewallRule -Name $SshRule -ErrorAction SilentlyContinue) { Ok "Windows Defender rule $SshRule exists" }
  elseif ($Apply) {
    New-NetFirewallRule -Name $SshRule -DisplayName "WSL sshd 2222 from the tailnet" -Direction Inbound -Protocol TCP `
      -LocalPort 2222 -RemoteAddress $Tailnet -Action Allow -Profile Any | Out-Null
    Ok "Windows Defender rule $SshRule created"
  } else { Would "create Windows Defender rule $SshRule (TCP 2222 from $Tailnet)" }
}

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
  Write-Host "`n  Put this in homelab-foundation inventory/network.yml: wake_on_lan.mac: $($eth.MacAddress -replace '-', ':')"
  Write-Host "  BIOS (by hand): Wake on LAN / Power on by PCI-E = Enabled, ErP = Disabled."
}

if (-not $Apply) { Write-Host "`nNothing was changed. To apply: add -Apply" -ForegroundColor Yellow }
