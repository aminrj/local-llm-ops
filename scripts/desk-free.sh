#!/usr/bin/env bash
set -uo pipefail

# Free the GPU from the desk model server, but only if the desk is idle.
#
# Used by lookout-llm-prewarm.service before it loads the assistant's model.
# The desk servers (8081 codemode, 8082 dense/bee, 8083 MTP) hold the card
# indefinitely, so something has to release it — but not while a long agent
# session is working, whichever model is loaded.
#
# "Active" = the log file the running server writes to (found through the
# process's own stdout, so it holds for any model or launcher) changed within
# the last IDLE_MINUTES. llama-server writes progress lines every few seconds
# while it prefills or generates, so a long turn keeps the log fresh.
#
# Exit codes (the unit treats 3 as success via SuccessExitStatus=3):
#   0  nothing to protect, or the desk was idle and has been stopped: go on
#   3  the desk is active: leave it alone and skip the pre-warm
#
#   IDLE_MINUTES=30   how long without log output counts as idle
#   DRY_RUN=1         report the decision, stop nothing
#   DESK_PORTS="8081 8082 8083"

IDLE_MINUTES="${IDLE_MINUTES:-30}"
DESK_PORTS="${DESK_PORTS:-8081 8082 8083}"
LOG_DIR="${LLAMA_LOG_DIR:-$HOME/.local/share/llama-logs}"
DRY_RUN="${DRY_RUN:-0}"

say() { echo "desk-free: $*"; }

# Match on the exact --port so a longer number never matches, and so this
# script's own command line cannot match itself (no literal pattern in argv).
pids=()
for port in $DESK_PORTS; do
  while read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "llama-server.*--port ${port}( |\$)" 2>/dev/null)
done

if [[ ${#pids[@]} -eq 0 ]]; then
  say "no desk server running; GPU is already free"
  exit 0
fi

now=$(date +%s)
newest=0
for pid in "${pids[@]}"; do
  # The server's stdout/stderr is redirected to its log file at launch.
  log=$(readlink "/proc/$pid/fd/2" 2>/dev/null || true)
  if [[ -z "$log" || ! -f "$log" ]]; then
    log=""
  fi
  m=0
  if [[ -n "$log" ]]; then
    m=$(stat -c %Y "$log" 2>/dev/null || echo 0)
  fi
  (( m > newest )) && newest=$m
done

# Could not tell (no readable log): fall back to every desk log, never the
# agent's. Failing safe means treating an unknown as active.
if (( newest == 0 )); then
  for f in "$LOG_DIR"/*.log; do
    case "$(basename "$f")" in agent*|*proxy*) continue ;; esac
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( m > newest )) && newest=$m
  done
fi
if (( newest == 0 )); then
  say "cannot determine desk activity; leaving it running"
  exit 3
fi

age=$(( now - newest ))
limit=$(( IDLE_MINUTES * 60 ))
if (( age < limit )); then
  say "desk active (log written ${age}s ago, idle threshold ${limit}s); leaving pid(s) ${pids[*]} running"
  exit 3
fi

say "desk idle for ${age}s (threshold ${limit}s)"
if [[ "$DRY_RUN" == "1" ]]; then
  say "DRY_RUN: would stop pid(s) ${pids[*]}"
  exit 0
fi

kill "${pids[@]}" 2>/dev/null || true
for _ in $(seq 1 30); do
  alive=0
  for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
  (( alive )) || { say "stopped pid(s) ${pids[*]}"; exit 0; }
  sleep 1
done
say "pid(s) ${pids[*]} did not exit within 30s; sending SIGKILL"
kill -9 "${pids[@]}" 2>/dev/null || true
sleep 5
exit 0
