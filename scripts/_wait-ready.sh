#!/usr/bin/env bash
set -uo pipefail

# Poll /health until the server answers, then report VRAM headroom.
# Backgrounding the server means the launcher exits 0 even when the model
# fails to load 30s later, so somebody has to actually check.

PORT="${1:?port required}"
LOG_FILE="${2:?log file required}"
TIMEOUT="${TIMEOUT:-300}"

printf "Loading model on :%s " "$PORT"
for ((i = 0; i < TIMEOUT; i++)); do
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo " READY"
    if command -v nvidia-smi &>/dev/null; then
      read -r used total < <(nvidia-smi --query-gpu=memory.used,memory.total \
        --format=csv,noheader,nounits -i 0 | tr -d ',')
      echo "VRAM: ${used} / ${total} MiB used ($((total - used)) MiB free)"
      if (( total - used < 700 )); then
        echo "WARNING: under 700 MiB headroom. This box throws 'CUDA error:" >&2
        echo "         unknown error' when the display driver needs memory." >&2
        echo "         Lower CTX or UBATCH." >&2
      fi
    fi
    exit 0
  fi
  # pgrep rather than $! — the server was launched from the parent shell.
  if ! pgrep -f "llama-server.*--port $PORT" >/dev/null 2>&1; then
    echo " FAILED"
    echo "Server exited during load. Last lines of $LOG_FILE:" >&2
    tail -20 "$LOG_FILE" >&2
    exit 1
  fi
  printf "."
  sleep 1
done

echo " TIMEOUT after ${TIMEOUT}s"
echo "Still loading or wedged — check: tail -f $LOG_FILE" >&2
exit 1
