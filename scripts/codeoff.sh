#!/usr/bin/env bash
set -euo pipefail

# Kill llama-server instances and wait for the VRAM to actually come back.
# Ports: 8081 codemode, 8082 beellama, 8083 MTP A/B candidate.
#
# The waiting is the point. `kill` returns immediately but the driver takes a
# second or two to release ~22 GB, so `codeoff && codemode` used to race and
# the new server would die on the leftover allocation.

echo "Stopping llama-server processes..."

mapfile -t pids < <(pgrep -f "llama-server" 2>/dev/null || true)

if [[ ${#pids[@]} -eq 0 ]]; then
  echo "  None running."
else
  for pid in "${pids[@]}"; do
    port=$(ss -ltnp 2>/dev/null | grep -oP "0.0.0.0:\K[0-9]+(?=.*pid=$pid,)" | head -1)
    echo "  PID $pid${port:+ (port $port)}"
    kill "$pid" 2>/dev/null || true
  done

  # Wait for graceful exit, then escalate.
  for _ in {1..15}; do
    pgrep -f "llama-server" >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -f "llama-server" >/dev/null 2>&1; then
    echo "  Still alive after 15s — sending SIGKILL."
    pkill -9 -f "llama-server" 2>/dev/null || true
    sleep 2
  fi
fi

# Report VRAM only once the driver has settled, otherwise the number is stale.
if command -v nvidia-smi &>/dev/null; then
  for _ in {1..10}; do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0 2>/dev/null || echo 0)
    (( used < 2000 )) && break
    sleep 1
  done
  total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0 2>/dev/null || echo 0)
  echo "VRAM: ${used} / ${total} MiB used"
fi
