#!/usr/bin/env bash
# Walk a set of server configs, benchmark each, record VRAM headroom.
# One model fits at a time, so this is necessarily sequential and slow
# (~5 min per config). Failures are logged and the sweep continues.
#
#   bash scripts/sweep.sh 2>&1 | tee ~/.local/share/llama-logs/sweep.log

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REPEATS="${REPEATS:-2}"
CTX_SIZES="${CTX_SIZES:-1000,16000,48000,96000}"

# label:script:env
CONFIGS=(
  "ub512:run-qwen3.6-35b-a3b.sh:CTX=131072 UBATCH=512"
  "ub1024:run-qwen3.6-35b-a3b.sh:CTX=131072 UBATCH=1024"
  "ub2048:run-qwen3.6-35b-a3b.sh:CTX=131072 UBATCH=2048"
  "ub1024-ctx98k:run-qwen3.6-35b-a3b.sh:CTX=98304 UBATCH=1024"
  "mtp-ctx98k:run-qwen3.6-35b-a3b-mtp.sh:CTX=98304 UBATCH=512"
)

echo "=== sweep started $(date -Is) ==="
echo "repeats=$REPEATS ctx_sizes=$CTX_SIZES"
echo

for entry in "${CONFIGS[@]}"; do
  label="${entry%%:*}"
  rest="${entry#*:}"
  script="${rest%%:*}"
  envs="${rest#*:}"

  echo "################################################################"
  echo "### $label  ($script  $envs)"
  echo "################################################################"

  bash scripts/codeoff.sh

  if ! env $envs bash "scripts/$script"; then
    echo "!!! $label FAILED TO LOAD — skipping"
    echo
    continue
  fi

  port=8081
  [[ "$script" == *mtp* ]] && port=8083

  python3 scripts/bench-ctx.py \
    --port "$port" --label "$label" \
    --repeats "$REPEATS" --ctx-sizes "$CTX_SIZES" \
    || echo "!!! $label BENCH FAILED"
  echo
done

bash scripts/codeoff.sh
echo "=== sweep finished $(date -Is) ==="
echo "Summarize with: python3 scripts/summarize-sweep.py"
