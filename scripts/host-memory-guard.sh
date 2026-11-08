#!/usr/bin/env bash
set -euo pipefail

# One-time host setup (needs root): act on memory pressure before the kernel
# OOM killer does, and choose the victim deliberately.
#
#   sudo bash scripts/host-memory-guard.sh          install or update
#   sudo bash scripts/host-memory-guard.sh --remove undo
#
# Why: the kernel OOM killer picks the largest process, and on this box that is
# always llama-server (12-17 GiB with --cache-ram 12288). Twice on 2026-11-08 a
# build (a Rust link inside `docker build`, and another big process) pushed the
# 28 GiB WSL VM over the edge and the model server was killed mid-session.
#
# earlyoom watches free RAM and swap and, when both run low, sends SIGTERM to
# one process before the kernel has to act. Build tools are preferred victims, so
# a runaway compile fails (and can be retried with less parallelism) while the
# model server, OpenCode, Claude Code, editors and shells are left alone unless
# nothing else is left to kill.

CONF=/etc/default/earlyoom

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run with sudo." >&2
  exit 1
fi

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now earlyoom 2>/dev/null || true
  apt-get remove -y earlyoom
  echo "earlyoom removed."
  exit 0
fi

command -v earlyoom >/dev/null 2>&1 || apt-get install -y earlyoom

# Thresholds: act when available RAM is under 8 % (about 2.2 GiB of 27 GiB)
# AND free swap is under 15 %. SIGKILL only at half of those.
# Process names are matched on /proc/<pid>/comm (15 characters max).
PREFER='^(ld|ld\.lld|lld|mold|collect2|cc1|cc1plus|rustc|cargo|clang|clang\+\+|gcc|g\+\+|node|esbuild|tsc|vitest|go|java|buildkitd|buildkit-runc)$'
AVOID='^(llama-server|opencode|claude|tmux: server|tmux|zsh|bash|sshd|systemd|systemd-journal|dockerd|containerd|nvim|python3)$'

cat > "$CONF" <<EOF
# Managed by local-llm-ops/scripts/host-memory-guard.sh
EARLYOOM_ARGS="-m 8,4 -s 15,8 -r 3600 --prefer '$PREFER' --avoid '$AVOID'"
EOF

systemctl enable earlyoom >/dev/null 2>&1 || true
systemctl restart earlyoom
sleep 1
systemctl --no-pager --lines=8 status earlyoom
echo
echo "earlyoom is active. Kills are logged: journalctl -u earlyoom"
