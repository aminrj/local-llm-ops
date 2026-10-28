#!/usr/bin/env bash
set -euo pipefail

# The personal assistant's model server: the same Qwen3.8-27B build and quant as
# `llm 38`, with a profile of its own.
#
#   - 127.0.0.1 only. The assistant VMs reach it through Caddy on :8743 with
#     mutual TLS (agent/Caddyfile), never directly.
#   - Two slots: the Inside and Outside agents can run at the same time. They
#     share the one unified KV cache, so one long job leaves less for the other.
#   - Its own alias and log, so `llm status` and the logs tell the two apart.
#   - An API key, so even a process on this machine can't use it by accident.
#   - Reasoning effort low by default; jobs ask for more per request.
#
# You don't run this by hand: the arbiter (scripts/arbiter.py) starts it when the
# GPU has been free long enough and stops it when you need the card. `llm 38`,
# `llm code`, `llm off` and `llm desk` stop it first, so your work always wins.
# The run script's guard refuses to start while any other llama-server runs.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${AGENT_CONF_DIR:-$HOME/.config/llm-agent}"

export PORT="${AGENT_PORT:-8090}"
export HOST="127.0.0.1"
export PARALLEL="${AGENT_PARALLEL:-2}"
export ALIAS="${AGENT_ALIAS:-qwen3.8-27b-agent}"
export EFFORT="${AGENT_EFFORT:-low}"
export API_KEY_FILE="${AGENT_API_KEY_FILE:-$CONF_DIR/api-key}"
export LOG_FILE="${AGENT_LOG_FILE:-$HOME/.local/share/llama-logs/agent.log}"
# Same measured defaults as the desk profile (README "Context ceiling, measured").
export CTX="${AGENT_CTX:-196608}"

exec bash "$HERE/run-qwen3.8-27b.sh" "$EFFORT"
