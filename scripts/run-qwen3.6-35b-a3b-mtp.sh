#!/usr/bin/env bash
set -euo pipefail

# A/B candidate: same model + quant as codemode, but the MTP build, which
# ships a multi-token-prediction draft head inside the single GGUF.
#
# This is NOT the draft-model speculative decoding that benchmarks negative on
# Ampere + A3B. That one runs a separate 0.8B drafter and pays the MoE expert
# load twice. The MTP head shares the trunk, so the cost model is different —
# which is exactly why it's worth measuring rather than assuming.
#
# Port 8083 so it never collides with codemode (8081) or beellama (8082).

LOG_DIR="$HOME/.local/share/llama-logs"
mkdir -p "$LOG_DIR"

MODEL_DIR="${MODEL_DIR:-$HOME/models/Qwen3.6-35B-A3B-MTP}"
PORT="${PORT:-8083}"
CTX="${CTX:-131072}"
UBATCH="${UBATCH:-512}"
DRAFT_MAX="${DRAFT_MAX:-3}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/codemode-mtp.log}"

SERVER="$HOME/llama.cpp/build/bin/llama-server"
MODEL="$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"

if [ ! -x "$SERVER" ]; then
  echo "ERROR: llama-server not built. Run: make build-llamacpp" >&2
  exit 1
fi

if [ ! -f "$MODEL" ]; then
  echo "ERROR: MTP model not found at $MODEL" >&2
  echo "Run: make download-qwen3.6-mtp" >&2
  exit 1
fi

# 24 GB fits exactly one of these models. Starting a second is how you get
# 'CUDA error: unknown error' instead of a benchmark.
if pgrep -f "llama-server" >/dev/null 2>&1; then
  echo "ERROR: another llama-server is running — the GPU only fits one." >&2
  echo "Run codeoff first, then retry." >&2
  exit 1
fi

nohup "$SERVER" \
  --model  "$MODEL" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --no-mmproj-offload \
  --alias  "qwen3.6-35b-a3b-mtp" \
  --port "$PORT" --host 0.0.0.0 \
  --spec-type draft-mtp \
  --spec-draft-n-max "$DRAFT_MAX" \
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
