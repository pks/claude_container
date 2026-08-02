#!/bin/bash
# Start the agent inside a detached tmux session so it has a tty (docker run -it
# in run.sh requires one) and so the operator can `tmux attach -t diffusemt`.
#
# Robust against Mithril relocation races (see diffusemt-resume.service):
#   - The exp volume and the docker daemon attach *asynchronously* on a
#     relocation boot. The systemd unit only orders us after them (soft After=),
#     it does not block on them — so we wait here before launching.
#   - Idempotency keys on a live *container*, not the tmux session. A preempted
#     run leaves its session sitting at `exec bash` with a DEAD agent; the old
#     `tmux has-session` guard mistook that for "already running" and skipped
#     the relaunch, leaving the GPU idle. We instead check for a running
#     container from our image, and clear any stale session before launching.
#
# PROFILE/GPU default to empty so run.sh falls through to $STATE_DIR/.config
# (written on first fresh start). Override via /home/ubuntu/exp/.diffusemt-resume.env.
set -euo pipefail

SESSION="${TMUX_SESSION:-diffusemt}"
PROFILE="${PROFILE:-}"
GPU="${GPU:-}"
REPO="${REPO:-/home/ubuntu/exp/diffusemt}"
MOUNT="${MOUNT:-/home/ubuntu/exp}"
IMAGE="${IMAGE:-claude-container}"
WAIT_SECS="${WAIT_SECS:-300}"

log() { echo "resume: $*" >&2; }

# 1. Wait for the persistent volume to actually be mounted (async on relocation).
for ((i = 0; i < WAIT_SECS; i += 5)); do
  mountpoint -q "$MOUNT" && break
  log "waiting for $MOUNT to mount (${i}s/${WAIT_SECS}s)"
  sleep 5
done
if ! mountpoint -q "$MOUNT"; then
  log "ERROR: $MOUNT not mounted after ${WAIT_SECS}s; aborting (resume manually once attached)"
  exit 1
fi

# 2. Wait for the docker daemon.
for ((i = 0; i < WAIT_SECS; i += 5)); do
  docker info >/dev/null 2>&1 && break
  log "waiting for docker daemon (${i}s/${WAIT_SECS}s)"
  sleep 5
done
if ! docker info >/dev/null 2>&1; then
  log "ERROR: docker daemon not ready after ${WAIT_SECS}s; aborting"
  exit 1
fi

# 3. Already running? Key on a live container from our image, NOT the tmux
#    session — a preempted run leaves a dead-agent session behind. run.sh runs
#    the container from $IMAGE with --rm and no --name, so `ancestor=` is the
#    reliable liveness signal.
if [ -n "$(docker ps --filter "ancestor=${IMAGE}" --format '{{.ID}}')" ]; then
  log "a ${IMAGE} container is already running; leaving as-is"
  exit 0
fi

# 4. Clear any stale (dead-agent) session, then launch. `exec bash` keeps the
#    pane alive post-exit so the operator can inspect the tail of the output.
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -c "$REPO" \
  "PROFILE='$PROFILE' GPU='$GPU' make run; exec bash"
log "launched 'make run' in tmux session '$SESSION'"
