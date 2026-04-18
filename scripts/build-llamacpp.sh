#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR="$HOME/llama.cpp"

echo "==> Updating llama.cpp source..."
git -C "$LLAMA_DIR" pull

echo "==> Configuring cmake (CUDA, static)..."
cmake "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=ON

echo "==> Building llama-server ($(nproc) threads)..."
cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)" --target llama-server

echo "==> Installing binary..."
cp "$LLAMA_DIR/build/bin/llama-server" "$LLAMA_DIR/llama-server"

echo "==> Done."
"$LLAMA_DIR/llama-server" --version
