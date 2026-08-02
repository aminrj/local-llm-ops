#!/usr/bin/env bash
set -euo pipefail

# Must match MODEL_DIR in run-qwen3.6-35b-a3b.sh.
DEST="${DEST:-$HOME/models/Qwen3.6-35B-A3B}"

if ! command -v hf &>/dev/null; then
  echo "ERROR: hf not found. Install with: pip install -U huggingface_hub" >&2
  exit 1
fi

hf download unsloth/Qwen3.6-35B-A3B-GGUF \
  --local-dir "$DEST" \
  --include "*UD-Q4_K_XL*" \
  --include "*mmproj-F16*"
