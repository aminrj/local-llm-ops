#!/usr/bin/env bash
set -euo pipefail

# Log directory
LOG_DIR="$HOME/.local/share/llama-logs"
mkdir -p "$LOG_DIR"

# BeeLlama.cpp — Qwen3.6 27B Q5_K_S + DFlash speculative decoding
# "Precision" combo: Q5 target + Q4 drafter + turbo4 K cache + turbo3_tcq V cache
# Port 8082 (codemode uses 8081)

MODEL_DIR="${MODEL_DIR:-$HOME/models/Qwen3.6-27B-DFlash}"
PORT="${PORT:-8082}"
# Host-side KV cache for idle slots. Set CACHE_RAM=0 to restore the previous
# behaviour if this fork handles it differently from upstream.
CACHE_RAM="${CACHE_RAM:-8192}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/beellama.log}"
BEE_SERVER="$HOME/beellama.cpp/build/bin/llama-server"

if [ ! -x "$BEE_SERVER" ]; then
  echo "ERROR: BeeLlama.cpp not built. Run:"
  echo "  cd $HOME/beellama.cpp && cmake -B build -DGGML_CUDA=ON -DGGML_NATIVE=ON \\"
  echo "    -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DCMAKE_CUDA_ARCHITECTURES=86 \\"
  echo "    -DCMAKE_BUILD_TYPE=Release && cmake --build build --target llama-server"
  exit 1
fi

# 24 GB fits exactly one of these models.
if pgrep -f "llama-server" >/dev/null 2>&1; then
  echo "ERROR: another llama-server is running — the GPU only fits one." >&2
  echo "Run codeoff first, then retry." >&2
  exit 1
fi

# Run in background, fully detached from terminal
nohup "$BEE_SERVER" \
  --model  "$MODEL_DIR/Qwen3.6-27B-Q5_K_S.gguf" \
  --mmproj "$MODEL_DIR/mmproj-BF16.gguf" \
  --no-mmproj-offload \
  --spec-draft-model "$MODEL_DIR/dflash-draft-3.6-q4_k_m.gguf" \
  --spec-type dflash \
  --spec-dflash-cross-ctx 1024 \
  --port "$PORT" --host 0.0.0.0 \
  -np 1 \
  --kv-unified \
  -ngl all \
  --spec-draft-ngl all \
  -b 2048 -ub 256 \
  --ctx-size 122800 \
  --cache-type-k turbo4 --cache-type-v turbo3_tcq \
  --flash-attn on \
  --cache-ram "$CACHE_RAM" \
  --jinja \
  --no-mmap --mlock \
  --no-host --metrics \
  --log-timestamps --log-prefix --log-colors off \
  --reasoning on \
  --chat-template-kwargs '{"preserve_thinking":true}' \
  --temp 0.6 --top-k 20 --min-p 0.0 \
  -to 3600 \
  >>"$LOG_FILE" 2>&1 < /dev/null &

builtin disown

exec bash "$(dirname "${BASH_SOURCE[0]}")/_wait-ready.sh" "$PORT" "$LOG_FILE"
