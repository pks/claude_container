#!/bin/bash
# Resume the MT-bench agent after a preemption reboot. Relaunches the bench
# through ops/bench-egress.sh — so the egress lock AND the compute-time budget
# apply on resume (elapsed is read from the durable STATE_DIR, downtime is free).
#
# Hardened against relocation races (learned in the pilot):
#   - waits for the durable state volume + docker (both attach async on a fresh
#     boot); the unit only orders after them, it doesn't block.
#   - idempotency keys on a live AGENT container (image match, excluding the
#     proxy), NOT a tmux session — a preempted run leaves a session with a dead
#     agent, which the naive `tmux has-session` guard mistook for "running".
#   - skips a run already marked complete (.bench_done).
set -euo pipefail

SESSION="${TMUX_SESSION:-mtbench}"
REPO="${REPO:-/home/ubuntu/mtbench}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
MOUNT="${MOUNT:-$STATE_DIR}"
IMAGE="${IMAGE:-mtbench-container}"
PROXY_NAME="${PROXY_NAME:-mtbench-proxy}"
PROFILE="${PROFILE:-}"
GPU="${GPU:-}"
WAIT_SECS="${WAIT_SECS:-300}"

log() { echo "bench-resume: $*" >&2; }

# 1. Wait for the durable state volume (async on a fresh/relocated boot). If the
#    state is a plain dir (no separate mount), the -d fallback lets us proceed.
for ((i = 0; i < WAIT_SECS; i += 5)); do
  mountpoint -q "$MOUNT" 2>/dev/null && break
  [ "$MOUNT" = "$STATE_DIR" ] && [ -d "$STATE_DIR" ] && break
  log "waiting for state volume at $MOUNT (${i}s/${WAIT_SECS}s)"
  sleep 5
done

# 2. Wait for the docker daemon.
for ((i = 0; i < WAIT_SECS; i += 5)); do
  docker info >/dev/null 2>&1 && break
  log "waiting for docker daemon (${i}s/${WAIT_SECS}s)"
  sleep 5
done
docker info >/dev/null 2>&1 || { log "ERROR: docker not ready after ${WAIT_SECS}s; aborting"; exit 1; }

# 3. Run already complete? Don't relaunch.
if [ -f "$STATE_DIR/.bench_done" ]; then
  log "run already complete ($STATE_DIR/.bench_done); nothing to do"
  exit 0
fi

# 4. Already running? A live container from our image that is NOT the proxy.
running=$(docker ps --filter "ancestor=${IMAGE}" --format '{{.Names}}' | grep -v "^${PROXY_NAME}\$" || true)
if [ -n "$running" ]; then
  log "agent container already running ($running); leaving as-is"
  exit 0
fi

# 5. Clear any stale (dead-agent) session, then relaunch the bench through the
#    egress + compute-clock wrapper. `exec bash` keeps the pane alive for inspection.
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -c "$REPO" \
  "STATE_DIR='$STATE_DIR' IMAGE='$IMAGE' ./ops/bench-egress.sh '$PROFILE' '$GPU'; exec bash"
log "relaunched bench (ops/bench-egress.sh) in tmux session '$SESSION'"
