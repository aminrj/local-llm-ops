#!/usr/bin/env bash
set -euo pipefail

# Qwen3.6-35B-A3B with the MTP (multi-token prediction) draft head baked in.
# Same quant as the standard model, so it goes in its own directory: the
# filenames are identical and would otherwise overwrite the known-good GGUF.

DEST="${DEST:-$HOME/models/Qwen3.6-35B-A3B-MTP}"
REPO="unsloth/Qwen3.6-35B-A3B-MTP-GGUF"

if ! command -v hf &>/dev/null; then
  echo "ERROR: hf not found. Install with: pip install -U huggingface_hub" >&2
  exit 1
fi

echo "==> Downloading $REPO -> $DEST"
hf download "$REPO" \
  --local-dir "$DEST" \
  --include "*UD-Q4_K_XL*" \
  --include "*mmproj-F16*"

echo "==> Done."
du -sh "$DEST"
