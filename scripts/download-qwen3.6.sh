#!/usr/bin/env bash
set -euo pipefail

hf download unsloth/Qwen3.6-35B-A3B-GGUF \
  --local-dir /usr/share/ollama/.ollama/models/Qwen3.6-35B-A3B \
  --include "*UD-Q4_K_XL*" \
  --include "*mmproj-F16*"
