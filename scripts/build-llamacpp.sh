#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR="$HOME/llama.cpp"

echo "==> Updating llama.cpp source..."
git -C "$LLAMA_DIR" pull

echo "==> Configuring cmake (CUDA, native, FA kernels)..."
cmake "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  -DCMAKE_BUILD_TYPE=Release

echo "==> Building llama-server ($(nproc) threads)..."
cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)" --target llama-server

echo "==> Done."
"$LLAMA_DIR/build/bin/llama-server" --version
