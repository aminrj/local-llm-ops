#!/usr/bin/env bash
set -euo pipefail

# Link the opencode client config in this repo into ~/.config/opencode.
#
# opencode merges ~/.config/opencode/{config.json,opencode.json,opencode.jsonc}
# in that order, later wins. Everything but the plugin list lives in
# config.json; opencode.json carries only the plugin array. tui.json takes
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

for f in config.json opencode.json tui.json dcp.jsonc; do
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
