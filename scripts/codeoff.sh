#!/usr/bin/env bash
set -euo pipefail

# Kill llama-server instances to free VRAM
# Targets: port 8081 (qwen3.6-35b-a3b) and port 8082 (BeeLlama qwen3.6-27b)

echo "Killing llama-server processes..."

killed=0
for port in 8081 8082; do
  pid=$(lsof -ti :"$port" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    echo "  Port $port → PID $pid"
    kill "$pid" 2>/dev/null || true
    killed=$((killed + 1))
  fi
done

# Also kill any stray llama-server that might have escaped port detection
stray=$(pgrep -f "llama-server" 2>/dev/null || true)
if [[ -n "$stray" ]]; then
  echo "  Stray llama-server: $stray"
  kill $stray 2>/dev/null || true
  killed=$((killed + 1))
fi

if [[ $killed -eq 0 ]]; then
  echo "  No llama-server processes found."
else
  echo "Done. VRAM should be freed."
  nvidia-smi --query-gpu=memory.used --format=csv,noheader -i 0 2>/dev/null || true
fi
