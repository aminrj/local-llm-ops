#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="/usr/share/ollama/.ollama/models/Qwen3.6-35B-A3B"

exec "$HOME/llama.cpp/llama-server" \
  --model  "$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --alias  "qwen3.6-35b-a3b" \
  --port 8081 --host 0.0.0.0 \
  --ctx-size 65536 \
  --n-gpu-layers 99 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --cache-ram 4096 \
  --flash-attn on \
  --parallel 1
