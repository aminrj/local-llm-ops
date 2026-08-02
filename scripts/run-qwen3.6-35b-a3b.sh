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
UBATCH="${UBATCH:-512}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/codemode.log}"

SERVER="$HOME/llama.cpp/build/bin/llama-server"

if [ ! -x "$SERVER" ]; then
  echo "ERROR: llama-server not built. Run: make build-llamacpp" >&2
  exit 1
fi

# Refuse to start on top of a live server — otherwise the second process
# fights the first for the last ~400 MiB of VRAM and dies with a CUDA error.
if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
  echo "ERROR: something is already serving on port $PORT. Run codeoff first." >&2
  exit 1
fi

nohup "$SERVER" \
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
  -to 3600 \
  >>"$LOG_FILE" 2>&1 < /dev/null &

builtin disown

exec bash "$(dirname "${BASH_SOURCE[0]}")/_wait-ready.sh" "$PORT" "$LOG_FILE"
