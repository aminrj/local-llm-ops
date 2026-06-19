#!/usr/bin/env bash
set -euo pipefail

# Log directory
LOG_DIR="$HOME/.local/share/llama-logs"
mkdir -p "$LOG_DIR"

MODEL_DIR="$HOME/models/Qwen3.6-35B-A3B"

# Run in background, fully detached from terminal
nohup "$HOME/llama.cpp/build/bin/llama-server" \
  --model  "$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --alias  "qwen3.6-35b-a3b" \
  --port 8081 --host 0.0.0.0 \
  --ctx-size 120000 \
  --n-gpu-layers 99 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --cache-ram 0 \
  --flash-attn on \
  --defrag-thold 0.1 \
  -b 2048 -ub 512 \
  --no-mmap \
  --jinja \
  --no-context-shift \
  --chat-template-kwargs '{"preserve_thinking": true}' \
  -n 32768 \
  --parallel 1 \
  -to 3600 \
  >>"$LOG_DIR/codemode.log" 2>&1 < /dev/null &

# Disown so it survives terminal close
builtin disown
