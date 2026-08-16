#!/usr/bin/env bash
set -euo pipefail

# Override to build a second checkout without touching the one the daily
# driver runs on:  LLAMA_DIR=~/llama.cpp-38 bash scripts/build-llamacpp.sh
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"

if [ ! -d "$LLAMA_DIR/.git" ]; then
  echo "==> Cloning llama.cpp into $LLAMA_DIR..."
  git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
else
  echo "==> Updating llama.cpp source in $LLAMA_DIR..."
  git -C "$LLAMA_DIR" pull
fi

# nvcc is not on PATH in a non-interactive shell here, and cmake's CUDA probe
# fails with "No CMAKE_CUDA_COMPILER could be found" even though it located the
# toolkit. Point it at nvcc explicitly.
if ! command -v nvcc &>/dev/null; then
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
    if [ -x "$candidate" ]; then
      export CUDACXX="$candidate"
      export PATH="$(dirname "$candidate"):$PATH"
      echo "==> nvcc not on PATH, using $CUDACXX"
      break
    fi
  done
fi

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
