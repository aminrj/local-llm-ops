#!/bin/bash
# Download a single GGUF file from a HuggingFace repo into a local directory.
# Usage: ./scripts/download.sh <hf-repo> <filename> <dest-dir>
#
# Requires: huggingface-cli  (pip install huggingface_hub)
# Optional: set HF_TOKEN env var for gated models

set -euo pipefail

REPO="${1:?Usage: $0 <hf-repo> <filename> <dest-dir>}"
FILE="${2:?Usage: $0 <hf-repo> <filename> <dest-dir>}"
DEST="${3:?Usage: $0 <hf-repo> <filename> <dest-dir>}"

if ! command -v huggingface-cli &>/dev/null; then
  echo "ERROR: huggingface-cli not found. Install with: pip install huggingface_hub" >&2
  exit 1
fi

mkdir -p "$DEST"

echo "Downloading $FILE from $REPO → $DEST"
huggingface-cli download "$REPO" \
  --include "$FILE" \
  --local-dir "$DEST" \
  ${HF_TOKEN:+--token "$HF_TOKEN"}

echo ""
echo "Done: $DEST/$FILE"
echo ""
echo "Next steps:"
echo "  Register with Ollama:  make register-<modelname>"
echo "  Run via llama.cpp:     make run-<modelname>"
