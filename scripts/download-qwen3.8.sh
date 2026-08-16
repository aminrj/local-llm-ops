#!/usr/bin/env bash
set -euo pipefail

# Qwen3.8-27B, dense. Must match MODEL_DIR in run-qwen3.8-27b.sh.
#
# Two quants on purpose. 24 GB minus a display is ~19.6 GiB of usable
# envelope, and the MTP head is a separate 1.6 GiB file, so the 4-bit that
# fits at full context and the 3-bit that can also hold MTP are different
# files. Sweep them rather than guess.
DEST="${DEST:-$HOME/models/Qwen3.8-27B}"

if ! command -v hf &>/dev/null; then
  echo "ERROR: hf not found. Install with: pip install -U huggingface_hub" >&2
  exit 1
fi

# Main weights + vision projector.
# mmproj is F16 to match download-qwen3.6.sh; it runs on the CPU anyway
# (--no-mmproj-offload), so BF16 buys nothing here.
hf download unsloth/Qwen3.8-27B-GGUF \
  --local-dir "$DEST" \
  --include "*IQ4_XS*" \
  --include "*UD-Q3_K_XL*" \
  --include "*mmproj-F16*"

# MTP draft head for --spec-type draft-mtp.
# unsloth ships no separate MTP file; ggml-org does. Whether unsloth's main
# quants carry the layers inline is unverified — check the tensor list before
# trusting either path.
hf download ggml-org/Qwen3.8-27B-GGUF \
  --local-dir "$DEST" \
  --include "mtp-Qwen3.8-27B-Q4_0.gguf"

echo ""
echo "Done. Contents of $DEST:"
ls -la "$DEST"
