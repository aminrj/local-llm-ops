#!/usr/bin/env bash
set -euo pipefail

# Qwen3.8-27B, dense, on upstream llama.cpp.
#
# Runs from a SECOND checkout ($HOME/llama.cpp-38) so that pulling upstream for
# Qwen3.8 architecture support cannot regress the 35B-A3B daily driver, which
# stays on the known-good build in $HOME/llama.cpp.
#
# Port 8082 is the dense-27B slot (8081 codemode, 8083 MTP A/B).
# opencode reaches it via the "llamacpp-27b" provider; the model name there
# must match --alias below.

LOG_DIR="$HOME/.local/share/llama-logs"
mkdir -p "$LOG_DIR"

MODEL_DIR="${MODEL_DIR:-$HOME/models/Qwen3.8-27B}"
QUANT="${QUANT:-IQ4_XS}"          # IQ4_XS | UD-Q3_K_XL
PORT="${PORT:-8082}"
# 196608 measured at 2340 MiB free — safer than codemode's own 1161 MiB.
# 262144 (the model's native ceiling) loads but leaves 422 MiB, which is the
# regime that produces 'CUDA error: unknown error' on a card driving a display.
CTX="${CTX:-196608}"
UBATCH="${UBATCH:-1024}"
# Any --spec-type the binary accepts: none, draft-mtp, draft-dflash,
# ngram-mod, ngram-cache, ngram-simple, ...
# The ngram-* variants load no draft model, so they cost no VRAM — on a 24 GB
# card carrying a display that may beat draft-mtp even at a lower accept rate.
SPEC="${SPEC:-draft-mtp}"
# Measured on this box, not inherited: n-max 3 wins at 48k/96k, which is where
# agentic coding lives. n-max 4-6 are faster at 1k and worse at depth as draft
# acceptance collapses (0.67 -> 0.40 at 48k). See README.
SPEC_NMAX="${SPEC_NMAX:-3}"
# The chat template's own default is xhigh on this model, and xhigh is why the
# dense 27B felt slow: measured over 562 logged turns it emitted a median 385
# generated tokens per turn against the MoE's 192, which is most of the 13.2s
# vs 4.0s median turn time — decode itself is only ~1.3x slower.
#
# medium is the default here. Override per launch, either way round:
#   llm 38 low            positional
#   EFFORT=xhigh llm 38   environment
#
# The server flag only sets the default; llama.cpp also honours a per-request
# `reasoning_effort` field, so a client can still override it turn by turn.
# Levels: minimal|low|medium|high|xhigh|max, or 'default' for the template's.
EFFORT="${EFFORT:-medium}"

# A positional argument wins over the environment, so `llm 38 low` works
# without exporting anything. Reject anything else rather than handing an
# unknown string to the template.
if [ $# -gt 0 ]; then
  case "$1" in
    minimal|low|medium|high|xhigh|max|default) EFFORT="$1"; shift ;;
    *) echo "ERROR: unknown reasoning effort '$1'." >&2
       echo "       Expected one of: minimal low medium high xhigh max default" >&2
       exit 1 ;;
  esac
fi
# 8192 was too small: the log shows three 'prompt state size N MiB exceeds
# cache size limit 8192.000 MiB, skipping' events at 9826 / 14439 / 16696 MiB,
# each of which costs a full re-prefill (~216 t/s at depth) on the way back.
# With opencode now compacting at 160k the state tops out near 13.6 GiB;
# 12288 covers the common case on a 28 GiB box. Raise to 14336 to cover all
# of it if RAM pressure allows.
CACHE_RAM="${CACHE_RAM:-12288}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/qwen38.log}"
SERVER="${SERVER:-$HOME/llama.cpp-38/build/bin/llama-server}"
# Defaults keep the desk server exactly as it was. The assistant profile
# (scripts/run-agent.sh) overrides these: loopback only, two slots, its own
# alias, and an API key so only the TLS front end (Caddy, agent/) can use it.
HOST="${HOST:-0.0.0.0}"
PARALLEL="${PARALLEL:-1}"
ALIAS="${ALIAS:-qwen3.8-27b}"
API_KEY_FILE="${API_KEY_FILE:-}"

MODEL_FILE="$MODEL_DIR/Qwen3.8-27B-$QUANT.gguf"

if [ ! -x "$SERVER" ]; then
  echo "ERROR: $SERVER not built. Run:" >&2
  echo "  LLAMA_DIR=\$HOME/llama.cpp-38 bash scripts/build-llamacpp.sh" >&2
  exit 1
fi

if [ ! -f "$MODEL_FILE" ]; then
  echo "ERROR: $MODEL_FILE not found. Run: make download-qwen3.8" >&2
  echo "Available:" >&2
  ls -1 "$MODEL_DIR"/*.gguf 2>/dev/null >&2 || echo "  (nothing downloaded)" >&2
  exit 1
fi

# 24 GB fits exactly one of these models.
if pgrep -f "llama-server" >/dev/null 2>&1; then
  echo "ERROR: another llama-server is running — the GPU only fits one." >&2
  echo "Run codeoff first, then retry." >&2
  exit 1
fi

# The MTP head is a separate 1.6 GiB file in the ggml-org repo. Whether the
# unsloth quants carry the layers inline is unverified, so pass the file when
# it is on disk and let the server tell us if it was not needed.
# The unsloth quants carry the MTP head inline — the server logs
# blk.64.nextn.* as "unused tensor ... ignoring" when spec is off — so
# draft-mtp needs no separate file, and attaching one would waste 1.6 GiB.
# Set MTP_FILE explicitly to override (e.g. the ggml-org standalone head).
SPEC_ARGS=()
if [[ "$SPEC" != "none" && "$SPEC" != "off" ]]; then
  SPEC_ARGS=(--spec-type "$SPEC" --spec-draft-n-max "$SPEC_NMAX")
  if [ -n "${MTP_FILE:-}" ]; then
    SPEC_ARGS+=(--spec-draft-model "$MTP_FILE")
  fi
fi

AUTH_ARGS=()
if [ -n "$API_KEY_FILE" ]; then
  [ -r "$API_KEY_FILE" ] || { echo "ERROR: API_KEY_FILE $API_KEY_FILE is not readable." >&2; exit 1; }
  AUTH_ARGS=(--api-key-file "$API_KEY_FILE")
fi

echo "model=$(basename "$MODEL_FILE") ctx=$CTX ub=$UBATCH spec=$SPEC effort=$EFFORT host=$HOST port=$PORT parallel=$PARALLEL"

nohup "$SERVER" \
  --model  "$MODEL_FILE" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --no-mmproj-offload \
  --alias  "$ALIAS" \
  --port "$PORT" --host "$HOST" \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  --ctx-size "$CTX" \
  --n-gpu-layers 99 \
  "${SPEC_ARGS[@]}" \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --cache-ram "$CACHE_RAM" \
  --kv-unified \
  --flash-attn on \
  -b 2048 -ub "$UBATCH" \
  --no-mmap \
  --jinja \
  --no-context-shift \
  --reasoning-effort "$EFFORT" \
  --reasoning-preserve \
  -n 32768 \
  --parallel "$PARALLEL" \
  -to 3600 \
  >>"$LOG_FILE" 2>&1 < /dev/null &

builtin disown

exec bash "$(dirname "${BASH_SOURCE[0]}")/_wait-ready.sh" "$PORT" "$LOG_FILE"
