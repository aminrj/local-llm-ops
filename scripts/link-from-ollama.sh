#!/bin/bash
# Create ~/models/<name>/<name>.gguf symlinks pointing to Ollama's blob store.
# Run once after adding new models via `ollama pull`.
# No files are copied — the symlink lets llama.cpp and other tools see the model
# at a predictable path without duplicating the data.
#
# Usage: ./scripts/link-from-ollama.sh [--dry-run]

set -euo pipefail

BLOBS_DIR="/usr/share/ollama/.ollama/models/blobs"
MANIFESTS_DIR="/usr/share/ollama/.ollama/models/manifests"
MODELS_DIR="${HOME}/models"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -d "$MANIFESTS_DIR" ]]; then
  echo "ERROR: manifests directory not found: $MANIFESTS_DIR" >&2
  exit 1
fi

created=0
skipped=0
errors=0

while IFS= read -r -d '' manifest; do
  # Turn path into a model name: strip manifests dir prefix, replace / with :
  rel="${manifest#$MANIFESTS_DIR/}"
  full_name="${rel//\//:}"

  # Extract blob digest for the model layer
  blob=$(python3 - "$manifest" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
for layer in m.get("layers", []):
    if layer.get("mediaType") == "application/vnd.ollama.image.model":
        print(layer["digest"].replace(":", "-"))
        break
PYEOF
)

  if [[ -z "$blob" ]]; then
    echo "SKIP (no model layer): $full_name"
    ((skipped++)) || true
    continue
  fi

  blob_path="$BLOBS_DIR/$blob"
  if [[ ! -f "$blob_path" ]]; then
    echo "WARN (blob missing): $blob_path  [$full_name]"
    ((errors++)) || true
    continue
  fi

  # Build a clean short name: strip registry prefix, replace : with -
  short_name=$(echo "$full_name" \
    | sed 's|^registry\.ollama\.ai:[^:]*:||' \
    | tr ':' '-')

  link_dir="$MODELS_DIR/$short_name"
  link_path="$link_dir/$short_name.gguf"

  if [[ -L "$link_path" ]]; then
    echo "EXISTS: $link_path"
    ((skipped++)) || true
    continue
  fi

  echo "LINK:   $link_path  ->  $blob_path"
  if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$link_dir"
    ln -s "$blob_path" "$link_path"
  fi
  ((created++)) || true

done < <(find "$MANIFESTS_DIR" -type f -print0)

echo ""
echo "Done. Created: $created  Skipped: $skipped  Errors: $errors"
if [[ "$DRY_RUN" == true ]]; then
  echo "(dry-run — no files were written)"
fi
