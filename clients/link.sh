#!/usr/bin/env bash
set -euo pipefail

# Link the opencode client config in this repo into ~/.config/opencode.
#
# opencode v2 reads only ~/.config/opencode/opencode.json(c); v1's config.json
# is ignored, so providers, models, compaction and plugins all live in
# opencode.json (v2 key names: providers/package/settings). tui.json takes
# theme and keybinds and nothing else — a plugin array there is ignored.
#
# The rest of ~/.config/opencode (skills/, node_modules/) stays out of the
# repo, which is why these are symlinks rather than the directory itself.
#
#   clients/link.sh          link them
#   clients/link.sh --check  report without changing anything

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/opencode"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

mkdir -p "$DEST"

for f in opencode.json tui.json dcp.jsonc; do
  src="$HERE/opencode/$f"
  dst="$DEST/$f"
  [[ -f "$src" ]] || { echo "  ! missing in repo: $f" >&2; continue; }

  if [[ -L "$dst" && "$(readlink -f "$dst")" == "$src" ]]; then
    echo "  = $f"
    continue
  fi

  if (( CHECK )); then
    echo "  ~ $f would be linked"
    continue
  fi

  # Never discard a real file silently — keep a dated copy first.
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    cp "$dst" "$dst.bak-$(date +%Y%m%d-%H%M%S)"
    echo "  ~ $f (existing file backed up)"
  else
    echo "  + $f"
  fi
  ln -sfn "$src" "$dst"
done

if (( ! CHECK )); then
  echo
  echo "opencode reads these at startup — restart it to pick up changes."
fi
