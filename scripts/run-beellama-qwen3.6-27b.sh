#!/usr/bin/env bash
set -euo pipefail

# Log directory
LOG_DIR="$HOME/.local/share/llama-logs"
mkdir -p "$LOG_DIR"

# BeeLlama.cpp — Qwen3.6 27B Q5_K_S + DFlash speculative decoding
# "Precision" combo: Q5 target + Q4 drafter + turbo4 K cache + turbo3_tcq V cache
# Port 8082 (codemode uses 8081)

MODEL_DIR="/home/amine/models/Qwen3.6-27B-DFlash"
BEE_SERVER="$HOME/beellama.cpp/build/bin/llama-server"

if [ ! -x "$BEE_SERVER" ]; then
  echo "ERROR: BeeLlama.cpp not built. Run:"
  echo "  cd $HOME/beellama.cpp && cmake -B build -DGGML_CUDA=ON -DGGML_NATIVE=ON \\"
  echo "    -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DCMAKE_CUDA_ARCHITECTURES=86 \\"
  echo "    -DCMAKE_BUILD_TYPE=Release && cmake --build build --target llama-server"
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
  --port 8082 --host 0.0.0.0 \
  -np 1 \
  --kv-unified \
  -ngl all \
  --spec-draft-ngl all \
  -b 2048 -ub 256 \
  --ctx-size 122800 \
  --cache-type-k turbo4 --cache-type-v turbo3_tcq \
  --flash-attn on \
  --cache-ram 0 \
  --jinja \
  --no-mmap --mlock \
  --no-host --metrics \
  --log-timestamps --log-prefix --log-colors off \
  --reasoning on \
  --chat-template-kwargs '{"preserve_thinking":true}' \
  --temp 0.6 --top-k 20 --min-p 0.0 \
  --defrag-thold 0.1 \
  -to 3600 \
  >>"$LOG_DIR/beellama.log" 2>&1 < /dev/null &

# Disown so it survives terminal close
builtin disown
