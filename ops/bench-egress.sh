#!/bin/bash
# Bench egress lock. Runs the agent on an --internal docker network (no route to
# the internet) whose ONLY reachable peer is an allowlist proxy that forwards to
# the inference endpoint host(s) and nothing else. Fail-closed: if the agent's
# HTTP client ignores the proxy env, it reaches nothing rather than leaking.
#
# Flow:  agent (internal net) --> proxy (internal + external nets) --> inference host
#
# Usage:  ./ops/bench-egress.sh [run.sh args...]
#   INFERENCE_ALLOWLIST  comma-separated allowed hostnames (else derived from AZURE_BASE_URL)
#   IMAGE                bench image (must have tinyproxy baked) [mtbench-container]
set -euo pipefail

IMAGE="${IMAGE:-mtbench-container}"
NET="${DOCKER_NETWORK:-mtbench-net}"
NET_EXT="${NET}-ext"
PROXY_NAME="${PROXY_NAME:-mtbench-proxy}"
PROXY_PORT=8888
STATE_DIR="${STATE_DIR:-$PWD/state}"
BENCH_BUDGET_S="${BENCH_BUDGET_S:-43200}"   # 12h of ACTIVE compute time (not wall)
TICK="${BENCH_TICK_S:-30}"                  # heartbeat granularity for the elapsed clock
GRACE="${BENCH_KILL_GRACE:-120}"            # SIGINT->SIGKILL grace at the cap
ELAPSED_FILE="$STATE_DIR/.bench_elapsed_s"
DONE_FILE="$STATE_DIR/.bench_done"

# Compute-time budget is fair under preemption: the run is complete only when it
# has used BENCH_BUDGET_S of ACTIVE time (or the agent finished). If a prior
# segment already marked done, or spent the budget, don't relaunch.
if [ -f "$DONE_FILE" ]; then
  echo "bench-egress: run already complete ($DONE_FILE) — not relaunching" >&2
  exit 0
fi
elapsed=$(cat "$ELAPSED_FILE" 2>/dev/null || echo 0)
if [ "$elapsed" -ge "$BENCH_BUDGET_S" ]; then
  echo "bench-egress: compute budget spent (${elapsed}/${BENCH_BUDGET_S}s) — marking done" >&2
  touch "$DONE_FILE"; exit 0
fi
remaining=$(( BENCH_BUDGET_S - elapsed ))

# Pull the .env so AZURE_BASE_URL is visible for allowlist derivation (run.sh
# parses it again for the container; here we only need the host).
if [ -z "${INFERENCE_ALLOWLIST:-}" ] && [ -f .env ]; then
  base="$(grep -E '^[[:space:]]*(export[[:space:]]+)?AZURE_BASE_URL=' .env | tail -1 | sed -E 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//')"
  [ -n "$base" ] && INFERENCE_ALLOWLIST="$(printf '%s' "$base" | sed -E 's#^https?://##; s#/.*$##')"
fi
: "${INFERENCE_ALLOWLIST:?set INFERENCE_ALLOWLIST or put AZURE_BASE_URL in .env}"
echo "bench-egress: allowlist = $INFERENCE_ALLOWLIST" >&2

# internal net: no gateway to the outside → agent can't leak.
docker network inspect "$NET"     >/dev/null 2>&1 || docker network create --internal "$NET"
# egress-capable net: the proxy's outbound leg only.
docker network inspect "$NET_EXT" >/dev/null 2>&1 || docker network create "$NET_EXT"

# (re)start the proxy: on the internal net (agent talks to it) + the external net
# (it can reach the inference host). Nothing else bridges the two.
docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
# Proxy runs as the unprivileged image user (no --user 0): its entrypoint writes
# the allowlist to /tmp (world-writable) and tinyproxy binds :8888 (>1024), so it
# needs no root.
docker run -d --name "$PROXY_NAME" --network "$NET" \
  -e INFERENCE_ALLOWLIST="$INFERENCE_ALLOWLIST" \
  --entrypoint /usr/local/bin/proxy-entrypoint.sh "$IMAGE" >/dev/null
docker network connect "$NET_EXT" "$PROXY_NAME"
echo "bench-egress: proxy '$PROXY_NAME' up on network '$NET'" >&2

# Tear the proxy + networks down whenever we exit (cap hit, agent done, or error).
cleanup() {
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  docker network rm "$NET" "$NET_EXT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Run the agent pinned to the internal net + proxy env, capped at the REMAINING
# compute budget. A heartbeat persists elapsed active time every TICK; on a hard
# preemption the whole launcher dies but the last heartbeat survives on the
# durable STATE_DIR volume, so downtime costs nothing and the host-resume unit
# continues from it. At the cap: SIGINT (agent flushes its deliverable) then
# SIGKILL after grace. The deliverable is durable — /workspace is bind-mounted to
# $STATE_DIR/workspace, so whatever exists at stop time persists.
export IMAGE DOCKER_NETWORK="$NET"
export HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}"
export HTTP_PROXY="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1"

echo "bench-egress: ${elapsed}/${BENCH_BUDGET_S}s active used, ${remaining}s remaining" >&2
seg_start=$(date +%s)
( while :; do
    sleep "$TICK"
    e=$(( elapsed + $(date +%s) - seg_start ))
    [ "$e" -gt "$BENCH_BUDGET_S" ] && e=$BENCH_BUDGET_S
    printf '%s' "$e" > "$ELAPSED_FILE.tmp" && mv "$ELAPSED_FILE.tmp" "$ELAPSED_FILE"
  done ) &
HB=$!

rc=0
# --foreground is REQUIRED: without it timeout puts run.sh in a NEW process group,
# so `docker run -it` is no longer the terminal's foreground process and pi's
# interactive TUI can't own the TTY — it renders only to the container pty
# (visible via docker logs) and its input loop stalls after the first turn
# (observed on both nodes 2026-08-06). --foreground keeps run.sh in the terminal's
# foreground group so the TTY passes through; the time limit still fires.
timeout --foreground --signal=SIGINT --kill-after="${GRACE}" "${remaining}" ./run.sh "$@" || rc=$?

kill "$HB" 2>/dev/null || true
elapsed=$(( elapsed + $(date +%s) - seg_start ))
[ "$elapsed" -gt "$BENCH_BUDGET_S" ] && elapsed=$BENCH_BUDGET_S
printf '%s' "$elapsed" > "$ELAPSED_FILE"

# Done when: budget reached (rc=124 timeout, or elapsed>=budget) OR the agent
# exited cleanly (rc=0 = finished/idle). A crash (other rc) leaves the run
# resumable — the next launcher invocation continues from the persisted elapsed.
if [ "$rc" = 124 ] || [ "$elapsed" -ge "$BENCH_BUDGET_S" ] || [ "$rc" = 0 ]; then
  echo "bench-egress: run complete (rc=$rc, ${elapsed}/${BENCH_BUDGET_S}s active used)" >&2
  touch "$DONE_FILE"
else
  echo "bench-egress: segment ended rc=$rc, ${elapsed}/${BENCH_BUDGET_S}s used — resume will continue" >&2
fi
echo "bench-egress: deliverable in $STATE_DIR/workspace (model/ + decode.sh); score with bench/scorer/score.sh" >&2
