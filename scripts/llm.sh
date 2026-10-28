#!/usr/bin/env bash
set -uo pipefail

# One-command model switching. 24 GB fits exactly one model, so switching
# always means stop-then-start; this just does both and refuses to leave you
# with nothing running by accident.
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
One-command model switching. 24 GB fits exactly one model, so switching always
means stop-then-start; this does both and refuses to leave you with nothing
running by accident.

  llm 38 [effort]   Qwen3.8-27B dense   :8082   llamacpp-27b/qwen3.8-27b
  llm code          Qwen3.6-35B-A3B MoE :8081   llamacpp/qwen3.6-35b-a3b
  llm mtp           Qwen3.6-35B-A3B MTP :8083   llamacpp-mtp/qwen3.6-35b-a3b-mtp
  llm bee           Qwen3.6-27B DFlash  :8082   beellama/qwen3.6-27b-dflash
  llm off           stop everything (the assistant may take the GPU after 10 min)
  llm desk [hours]  keep the GPU for yourself (default 4 h): stops the assistant's model
  llm agent         lift the hold and let the assistant load its model now
  llm status        what is running, on which port, free VRAM, and the arbiter's state

Reasoning effort applies to `llm 38` only — it is the one model on a build
with --reasoning-effort. It defaults to medium; the template's own default is
xhigh, which roughly doubles generated tokens per turn.

  llm 38 low              minimal | low | medium | high | xhigh | max | default
  EFFORT=xhigh llm 38     same thing via the environment

USAGE
  exit "${1:-0}"
}

status() {
  local found=0
  # -m is not optional here: on this box a connection to a closed port hangs
  # until it times out rather than being refused, so an un-timed probe stalls
  # for as long as curl will wait.
  for port in 8081 8082 8083 8090; do
    if curl -sf -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      local alias_name
      alias_name=$(curl -sf -m 2 "http://127.0.0.1:$port/v1/models" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])' 2>/dev/null)
      echo "  :$port  ${alias_name:-unknown}"
      found=1
    fi
  done
  (( found )) || echo "  nothing serving"
  local arb
  arb=$(curl -sf -m 2 "http://127.0.0.1:8091/status" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"] + ": " + d["reason"])' 2>/dev/null)
  echo "  arbiter: ${arb:-not running (make agent-setup)}"
  if command -v nvidia-smi &>/dev/null; then
    read -r used total < <(nvidia-smi --query-gpu=memory.used,memory.total \
      --format=csv,noheader,nounits -i 0 | tr -d ',')
    echo "  VRAM: ${used} / ${total} MiB used ($((total - used)) MiB free)"
  fi
}

# Validate the effort here, before codeoff runs. The run script checks it too,
# but by then the previous server is already dead — a typo should not cost you
# a live session and a 150k-token re-prefill.
check_effort() {
  [ $# -eq 0 ] && return 0
  case "$1" in
    minimal|low|medium|high|xhigh|max|default) ;;
    *) echo "ERROR: unknown reasoning effort '$1'." >&2
       echo "       Expected one of: minimal low medium high xhigh max default" >&2
       exit 1 ;;
  esac
  if [ $# -gt 1 ]; then
    shift
    echo "ERROR: unexpected extra arguments: $*" >&2
    exit 1
  fi
}

# Only `llm 38` takes an argument. The others run on a build with no
# --reasoning-effort flag, so silently swallowing one would be a lie.
no_args() {
  local t="$1"; shift
  if [ $# -gt 0 ]; then
    echo "ERROR: 'llm $t' takes no arguments (got: $*)." >&2
    echo "       Reasoning effort is supported on 'llm 38' only." >&2
    exit 1
  fi
}

target="${1:-status}"

case "$target" in
  status|st)      echo "Serving:"; status ;;
  off|stop)       exec bash "$HERE/codeoff.sh" ;;
  desk)           shift; hours="${1:-4}"
                  [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: 'llm desk' takes hours, e.g. llm desk 4" >&2; exit 1; }
                  curl -sf -m 30 -X POST -H 'Content-Type: application/json' -d "{\"hours\": $hours}" \
                    http://127.0.0.1:8091/hold >/dev/null || { echo "ERROR: arbiter not running (make agent-setup)" >&2; exit 1; }
                  echo "GPU held for you for ${hours} h; the assistant's model is stopped."; status ;;
  agent)          shift; no_args "agent" "$@"
                  curl -sf -m 30 -X POST http://127.0.0.1:8091/release >/dev/null \
                    || { echo "ERROR: arbiter not running (make agent-setup)" >&2; exit 1; }
                  echo "Hold lifted; the assistant loads its model if nothing of yours is running."; status ;;
  38|qwen38|3.8)  shift; check_effort "$@"
                  bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-qwen3.8-27b.sh" "$@" ;;
  code|codemode)  shift; no_args "code" "$@"
                  bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-qwen3.6-35b-a3b.sh" ;;
  bee|beellama)   shift; no_args "bee" "$@"
                  bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-beellama-qwen3.6-27b.sh" ;;
  mtp)            shift; no_args "mtp" "$@"
                  bash "$HERE/codeoff.sh" >/dev/null 2>&1
                  exec bash "$HERE/run-qwen3.6-35b-a3b-mtp.sh" ;;
  -h|--help|help) usage 0 ;;
  *)              echo "Unknown target: $target" >&2; usage 1 ;;
esac
