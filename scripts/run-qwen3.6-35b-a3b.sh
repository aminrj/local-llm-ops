#!/usr/bin/env bash
set -euo pipefail

# Qwen3.6-35B-A3B (MoE, 8-of-256 experts) on a single RTX 3090.
# No speculative decoding: on Ampere + A3B every draft variant benchmarks
# net-negative, because verifying K drafted tokens loads the union of their
# expert sets. See README "Tuning notes".

LOG_DIR="$HOME/.local/share/llama-logs"
mkdir -p "$LOG_DIR"

MODEL_DIR="${MODEL_DIR:-$HOME/models/Qwen3.6-35B-A3B}"
PORT="${PORT:-8081}"
CTX="${CTX:-131072}"
# 1024 measured +15-21% prompt eval over 512 with decode unchanged, leaving
# 1161 MiB VRAM free. 2048 adds ~9% more but drops free VRAM to 476 MiB, which
# is the regime that produced six 'CUDA error: unknown error' crashes.
UBATCH="${UBATCH:-1024}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/codemode.log}"

SERVER="$HOME/llama.cpp/build/bin/llama-server"

if [ ! -x "$SERVER" ]; then
  echo "ERROR: llama-server not built. Run: make build-llamacpp" >&2
  exit 1
fi

# Refuse to start on top of any llama-server, not just one on this port: the
# assistant's server on :8090 counts too, and so does one still loading (it
# doesn't answer /health yet). Two ~22 GB models on the 24 GB card don't fail
# cleanly: CUDA spills the second into Windows' RAM and the whole PC freezes
# (2026-11-13).
if pgrep -x llama-server >/dev/null 2>&1; then
  echo "ERROR: another llama-server is running — the GPU only fits one." >&2
  pgrep -a -x llama-server | sed -E 's/^([0-9]+) .*--port ([0-9]+).*/  PID \1 on :\2/' >&2
  echo "Use 'llm code' (it stops the others first) or run codeoff, then retry." >&2
  exit 1
fi

bash "$(dirname "${BASH_SOURCE[0]}")/_launch-server.sh" "$PORT" "$LOG_FILE" -- "$SERVER" \
  --model  "$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --no-mmproj-offload \
  --alias  "qwen3.6-35b-a3b" \
  --port "$PORT" --host 0.0.0.0 \
  --ctx-size "$CTX" \
  --n-gpu-layers 99 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --cache-ram 8192 \
  --kv-unified \
  --flash-attn on \
  -b 2048 -ub "$UBATCH" \
  --no-mmap \
  --jinja \
  --no-context-shift \
  --chat-template-kwargs '{"preserve_thinking": true}' \
  -n 32768 \
  --parallel 1 \
  -to 3600

exec bash "$(dirname "${BASH_SOURCE[0]}")/_wait-ready.sh" "$PORT" "$LOG_FILE"
