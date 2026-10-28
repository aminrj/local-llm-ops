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
#   - ~/.config/llm-agent/arbiter.env with the defaults (edit it, then restart the unit)
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
if [ -f "$CONF/arbiter.env" ]; then
  ok "$CONF/arbiter.env (kept)"
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
EOF
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

(( YES )) || printf '\nNothing was changed. To apply: make agent-setup ARGS=--yes\n'
