#!/usr/bin/env bash
set -euo pipefail

# Installs the assistant's side of this box, idempotently. Changes nothing
# without --yes; prints what it would do.
#
#   make agent-setup              # check
#   make agent-setup ARGS=--yes   # apply
#
# What it sets up (all user-level, nothing touches your desk servers):
#   - caddy (apt) for the mutual-TLS front end on :8743; the system unit stays off
#   - systemd user units llm-arbiter and llm-agent-proxy, rendered for this repo path
#   - lingering for your user, so the units run without a login shell
#   - ~/.config/llm-agent/arbiter.env with the defaults (edit it, then restart the unit); keys
#     added later (AUTO_OFF*) are appended to an existing file, values you changed are kept
#   - sshd on port 2222 (keys only, this user only) so homelab-foundation can shut the PC down
#     (`make desktop-off`); Windows lets it in from the tailnet only (setup.ps1 -RemoteShutdown)
# What it expects from homelab-foundation (`make assistant-pki` there):
#   ~/.config/llm-agent/tls/{ca.crt,server.crt,server.key} and ~/.config/llm-agent/api-key

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$HOME/.config/llm-agent"
UNITS="$HOME/.config/systemd/user"
YES=0
[ "${1:-}" = "--yes" ] && YES=1

say()  { printf '\n== %s\n' "$*"; }
todo() { printf '  would: %s\n' "$*"; }
ok()   { printf '  ok: %s\n' "$*"; }
run()  { if (( YES )); then "$@"; else todo "$*"; fi; }

say "systemd in WSL"
if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
  echo "  PID 1 is not systemd. Add to /etc/wsl.conf:  [boot]  systemd=true  then 'wsl --shutdown' from Windows." >&2
  exit 1
fi
ok "systemd is PID 1"

say "caddy (official apt repo; Ubuntu 24.04's 2.6 lacks trust_pool and persist_config)"
CADDY_KEYRING=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
CADDY_LIST=/etc/apt/sources.list.d/caddy-stable.list
if [ -s "$CADDY_KEYRING" ] && [ -s "$CADDY_LIST" ]; then
  ok "repo $CADDY_LIST"
elif (( YES )); then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor --yes -o "$CADDY_KEYRING"
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee "$CADDY_LIST" >/dev/null
  sudo chmod o+r "$CADDY_KEYRING" "$CADDY_LIST"
  sudo apt-get update -q
else
  todo "add the Caddy stable apt repo ($CADDY_LIST, key from dl.cloudsmith.io)"
fi
caddy_ver="$(caddy version 2>/dev/null | sed -E 's/^v?([0-9]+)\.([0-9]+).*/\1 \2/')"
if [ -n "$caddy_ver" ] && read -r cmaj cmin <<<"$caddy_ver" && (( cmaj > 2 || (cmaj == 2 && cmin >= 8) )); then
  ok "$(caddy version | head -1)"
else
  run sudo apt-get install -y caddy
fi
if systemctl is-enabled caddy >/dev/null 2>&1; then
  # The packaged system unit would listen on :80 with its own Caddyfile; ours runs as a user unit.
  run sudo systemctl disable --now caddy
else
  ok "system caddy unit is off"
fi

say "certificates and API key (from homelab-foundation: make assistant-pki)"
missing=0
for f in tls/ca.crt tls/server.crt tls/server.key api-key; do
  if [ -s "$CONF/$f" ]; then ok "$CONF/$f"; else echo "  MISSING: $CONF/$f"; missing=1; fi
done
if (( missing )); then
  echo "  Run 'make assistant-pki ARGS=--yes' in homelab-foundation first; the units are installed but the proxy will not start." >&2
fi

say "arbiter settings"
# Auto-off (scripts/arbiter.py decide_power): the lab wakes the PC when the assistant needs it
# (homelab-foundation docs/runbooks/ai-desktop-power.md), so it switches itself off when idle.
AUTO_OFF_DEFAULTS="AUTO_OFF=1
AUTO_OFF_IDLE_SECONDS=1800
AUTO_OFF_GRACE_SECONDS=120
SSH_PORT=2222"
arbiter_env_changed=0
if [ -f "$CONF/arbiter.env" ]; then
  ok "$CONF/arbiter.env (kept)"
  while IFS= read -r line; do
    key="${line%%=*}"
    if grep -q "^$key=" "$CONF/arbiter.env"; then ok "$(grep "^$key=" "$CONF/arbiter.env")"
    elif (( YES )); then
      (( arbiter_env_changed )) || printf '# Auto-off: switch the PC off when idle (AUTO_OFF=0 disables it)\n' >> "$CONF/arbiter.env"
      printf '%s\n' "$line" >> "$CONF/arbiter.env"; arbiter_env_changed=1; ok "added $line"
    else todo "append $line to $CONF/arbiter.env"; fi
  done <<< "$AUTO_OFF_DEFAULTS"
else
  run mkdir -p "$CONF"
  if (( YES )); then
    cat > "$CONF/arbiter.env" <<'EOF'
# GPU arbiter settings (scripts/arbiter.py). Restart after editing:
#   systemctl --user restart llm-arbiter
QUIET_SECONDS=600
ONDEMAND_QUIET_SECONDS=120
VRAM_BUSY_MIB=3000
NIGHT_HANDOVER=0
NIGHT_HOUR=1
NIGHT_IDLE_SECONDS=7200
# Auto-off: switch the PC off when idle (AUTO_OFF=0 disables it)
EOF
    printf '%s\n' "$AUTO_OFF_DEFAULTS" >> "$CONF/arbiter.env"
    ok "wrote $CONF/arbiter.env"
  else
    todo "write $CONF/arbiter.env with the defaults"
  fi
fi

say "user units"
for u in llm-arbiter llm-agent-proxy; do
  rendered="$(sed "s#@REPO@#$REPO#g" "$REPO/agent/systemd/$u.service")"
  if [ -f "$UNITS/$u.service" ] && [ "$(cat "$UNITS/$u.service")" = "$rendered" ]; then
    ok "$u.service up to date"
  else
    if (( YES )); then
      mkdir -p "$UNITS" && printf '%s\n' "$rendered" > "$UNITS/$u.service" && ok "wrote $u.service"
    else
      todo "write $UNITS/$u.service"
    fi
  fi
done
run systemctl --user daemon-reload
run systemctl --user enable --now llm-arbiter
# A changed unit, script or arbiter.env only takes effect after a restart
if (( YES )); then systemctl --user restart llm-arbiter; ok "llm-arbiter restarted"
else todo "systemctl --user restart llm-arbiter"; fi
if (( ! missing )); then
  run systemctl --user enable --now llm-agent-proxy
  run systemctl --user restart llm-agent-proxy
fi

say "lingering (units run without an open shell)"
if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes; then
  ok "linger on"
else
  run sudo loginctl enable-linger "$USER"
fi

say "sshd on 2222 for remote shutdown (homelab-foundation make desktop-off; tailnet only via setup.ps1 -RemoteShutdown)"
# Keys only, this user only. With mirrored networking WSL's listeners sit on the Windows
# addresses; the Hyper-V firewall rule from setup.ps1 -RemoteShutdown lets 2222 in from the
# tailnet (100.64.0.0/10) and nothing else.
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-llm-agent.conf
SSHD_WANT="# Managed by local-llm-ops scripts/agent-setup.sh
Port 2222
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $USER"
if dpkg -s openssh-server >/dev/null 2>&1; then ok "openssh-server installed"; else run sudo apt-get install -y openssh-server; fi
if [ "$(cat "$SSHD_DROPIN" 2>/dev/null)" = "$SSHD_WANT" ]; then ok "$SSHD_DROPIN"
elif (( YES )); then
  printf '%s\n' "$SSHD_WANT" | sudo tee "$SSHD_DROPIN" >/dev/null
  sudo sshd -t
  # Ubuntu runs sshd socket-activated: the socket unit takes the port from sshd_config
  sudo systemctl daemon-reload
  sudo systemctl enable --now ssh.socket
  sudo systemctl restart ssh.socket
  ok "sshd on 2222 (keys only, $USER only)"
else todo "write $SSHD_DROPIN (Port 2222, keys only, AllowUsers $USER), restart ssh.socket"; fi
if [ -s "$HOME/.ssh/authorized_keys" ]; then ok "$(wc -l < "$HOME/.ssh/authorized_keys") key(s) in ~/.ssh/authorized_keys"
else echo "  NOTE: no ~/.ssh/authorized_keys: add the public keys of the machines that may shut this PC down (the Mac's)"; fi

(( YES )) || printf '\nNothing was changed. To apply: make agent-setup ARGS=--yes\n'
