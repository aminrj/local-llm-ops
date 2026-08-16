#!/usr/bin/env bash
set -uo pipefail

# One-command model switching. 24 GB fits exactly one model, so switching
# always means stop-then-start; this just does both and refuses to leave you
# with nothing running by accident.
#
#   llm 38       Qwen3.8-27B dense   :8082   [llamacpp-27b/qwen3.8-27b]
#   llm code     Qwen3.6-35B-A3B MoE :8081   [llamacpp/qwen3.6-35b-a3b]
#   llm bee      Qwen3.6-27B DFlash  :8082   [beellama/qwen3.6-27b-dflash]
#   llm off      stop everything
#   llm status   what is running, and on which port

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '4,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  exit "${1:-0}"
}

status() {
  local found=0
  # -m is not optional here: on this box a connection to a closed port hangs
  # until it times out rather than being refused, so an un-timed probe stalls
  # for as long as curl will wait.
  for port in 8081 8082 8083; do
    if curl -sf -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      local alias_name
      alias_name=$(curl -sf -m 2 "http://127.0.0.1:$port/v1/models" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])' 2>/dev/null)
      echo "  :$port  ${alias_name:-unknown}"
      found=1
    fi
  done
  (( found )) || echo "  nothing serving"
  if command -v nvidia-smi &>/dev/null; then
    read -r used total < <(nvidia-smi --query-gpu=memory.used,memory.total \
      --format=csv,noheader,nounits -i 0 | tr -d ',')
    echo "  VRAM: ${used} / ${total} MiB used ($((total - used)) MiB free)"
  fi
}

target="${1:-status}"

case "$target" in
  status|st)      echo "Serving:"; status ;;
  off|stop)       exec bash "$HERE/codeoff.sh" ;;
  38|qwen38|3.8)  bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  shift || true
                  exec bash "$HERE/run-qwen3.8-27b.sh" "$@" ;;
  code|codemode)  bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-qwen3.6-35b-a3b.sh" ;;
  bee|beellama)   bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-beellama-qwen3.6-27b.sh" ;;
  mtp)            bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-qwen3.6-35b-a3b-mtp.sh" ;;
  -h|--help|help) usage 0 ;;
  *)              echo "Unknown target: $target" >&2; usage 1 ;;
esac
