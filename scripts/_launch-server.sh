#!/usr/bin/env bash
set -euo pipefail

# Start a llama-server in its own systemd user unit, llm-<port>.service.
#
#   _launch-server.sh <port> <log-file> -- <server binary> [args...]
#
# Why a unit and not `nohup … &`: a backgrounded process stays in the cgroup of
# whoever started it. Started from a tmux pane, an OOM kill of the server made
# systemd stop the whole pane (OOMPolicy=stop): the shell, the OpenCode TUI and
# its server all died with it. Started by the arbiter, it would take the
# arbiter's service down the same way. In its own unit, an OOM kill ends only
# the server.
#
# stdout and stderr still go to the log file, so desk-free.sh (which finds the
# log through /proc/<pid>/fd/2) and _wait-ready.sh work unchanged, as do
# codeoff.sh and every pgrep on "llama-server".
#
# Falls back to the old nohup launch when no systemd user manager is reachable.

PORT="${1:?port required}"
LOG_FILE="${2:?log file required}"
shift 2
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "ERROR: no server command given." >&2; exit 1; }

UNIT="llm-$PORT"

if command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  # A previous run that died leaves a failed unit with this name behind.
  systemctl --user reset-failed "$UNIT.service" >/dev/null 2>&1 || true
  ENV_ARGS=(-E "PATH=$PATH" -E "HOME=$HOME")
  for v in LD_LIBRARY_PATH CUDA_VISIBLE_DEVICES CUDA_DEVICE_ORDER GGML_CUDA_ENABLE_UNIFIED_MEMORY; do
    [ -n "${!v:-}" ] && ENV_ARGS+=(-E "$v=${!v}")
  done
  systemd-run --user --quiet --collect \
    --unit="$UNIT" \
    --description="llama-server on :$PORT" \
    --working-directory="$HOME" \
    -p StandardInput=null \
    -p "StandardOutput=append:$LOG_FILE" \
    -p "StandardError=append:$LOG_FILE" \
    -p Restart=no \
    -p TimeoutStopSec=20 \
    "${ENV_ARGS[@]}" \
    "$@"
  echo "started as $UNIT.service (systemctl --user status $UNIT)"
else
  echo "no systemd user manager; starting with nohup" >&2
  nohup "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  builtin disown
fi
