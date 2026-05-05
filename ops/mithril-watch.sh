#!/bin/bash
# Polls /opt/mithril/MITHRIL_SIGNAL.yml for spot-interruption notices. While
# the signal is active:
#   1. SIGINT the agent (PID 1) every INTERRUPT_INTERVAL seconds until it
#      acks via /workspace/.shutdown-acked. This breaks the agent out of any
#      in-flight long-running tool call (e.g. a multi-hour training run) so
#      it sees the PreToolUse hook's shutdown context on its next turn.
#   2. Snapshot the running container into claude-container:resume every
#      SNAPSHOT_INTERVAL seconds via `docker commit`, so the most recent
#      writable layer (incl. the agent's final commit + STATUS.md) is
#      captured by the time the node goes down.
# Resets when the signal disappears, which Mithril does if the bid is
# re-allocated.
#
# Skips the interrupt when PID 1 isn't an agent (e.g. the `bash` profile
# drops you into an interactive shell — we shouldn't SIGINT the user).
set -u

SIG="${MITHRIL_SIGNAL_FILE:-/opt/mithril/MITHRIL_SIGNAL.yml}"
ACK="${SHUTDOWN_ACK_FILE:-/workspace/.shutdown-acked}"
CTR="${CONTAINER_NAME:?CONTAINER_NAME must be set}"
TAG="${RESUME_TAG:-claude-container:resume}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-30}"
INTERRUPT_INTERVAL="${INTERRUPT_INTERVAL:-45}"

# Sudo because the docker socket's group is the host's `docker` group, which
# the in-container user is not a member of. The image grants NOPASSWD sudo to
# the build user.
DOCKER="sudo -n docker"

log() { echo "[mithril-watch] $(date -Iseconds) $*"; }

# Don't SIGINT the user's shell if they invoked the `bash` profile.
pid1_comm=$(cat /proc/1/comm 2>/dev/null || echo unknown)
case "$pid1_comm" in
  bash|sh|zsh) INTERRUPT_PID1=0; log "PID 1 is $pid1_comm; SIGINT disabled" ;;
  *)           INTERRUPT_PID1=1 ;;
esac

snapshot_active=0
last_snapshot=0
last_interrupt=0

while :; do
  if [ -f "$SIG" ] && grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG" 2>/dev/null; then
    if [ "$snapshot_active" = 0 ]; then
      log "signal detected:"
      cat "$SIG" 2>/dev/null | sed 's/^/[mithril-watch]   /'
      snapshot_active=1
      last_snapshot=0
      last_interrupt=0
    fi
    now=$(date +%s)

    # Interrupt the agent so it breaks out of any in-flight long-running tool
    # call. Repeat every INTERRUPT_INTERVAL seconds until it acks. The
    # PreToolUse hook (mithril-hook.sh) delivers the shutdown context on the
    # agent's next tool call; SIGINT just guarantees that next tool call
    # happens promptly instead of after an hours-long training run.
    if [ "$INTERRUPT_PID1" = 1 ] && [ ! -f "$ACK" ]; then
      if [ $((now - last_interrupt)) -ge "$INTERRUPT_INTERVAL" ]; then
        log "SIGINT -> PID 1 ($pid1_comm) to interrupt in-flight work"
        kill -INT 1 || log "kill -INT 1 failed (rc=$?)"
        last_interrupt=$now
      fi
    fi

    if [ $((now - last_snapshot)) -ge "$SNAPSHOT_INTERVAL" ]; then
      log "snapshotting $CTR -> $TAG"
      if $DOCKER commit "$CTR" "$TAG"; then
        last_snapshot=$now
      else
        log "commit failed (rc=$?)"
      fi
    fi
    sleep "$POLL_INTERVAL"
  else
    if [ "$snapshot_active" = 1 ]; then
      log "signal cleared (bid restored?)"
      snapshot_active=0
    fi
    sleep "$POLL_INTERVAL"
  fi
done
