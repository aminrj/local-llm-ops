#!/usr/bin/env bash
set -euo pipefail

if ! command -v huggingface-cli &>/dev/null; then
  echo "ERROR: huggingface-cli not found. Install with: pip install huggingface_hub" >&2
  exit 1
fi

DEST="/usr/share/ollama/.ollama/models/Qwen3.6-35B-A3B"

huggingface-cli download unsloth/Qwen3.6-35B-A3B-GGUF \
  --local-dir "$DEST" \
  --include "*UD-Q4_K_XL*" \
  --include "*mmproj-F16*"
