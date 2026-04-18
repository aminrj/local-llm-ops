#!/bin/bash
# Register all models that have a Modelfile with Ollama.
# Useful after a fresh clone or when adding several models at once.
# Usage: ./scripts/register-ollama.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/../models"

if ! command -v ollama &>/dev/null; then
  echo "ERROR: ollama not found. Install from https://ollama.com" >&2
  exit 1
fi

for mf in "$MODELS_DIR"/*.Modelfile; do
  name=$(basename "$mf" .Modelfile)
  echo "Registering $name …"
  ollama create "$name" -f "$mf"
  echo "  OK: $name"
done

echo ""
echo "Registered models:"
ollama list
