#!/bin/bash
# Polls /opt/mithril/MITHRIL_SIGNAL.yml for spot-interruption notices and, while
# the signal is active, snapshots the running container into the
# claude-container:resume image tag via `docker commit`. Re-snapshots every
# SNAPSHOT_INTERVAL seconds so the saved image tracks the agent's most recent
# state (e.g. its final commit + STATUS.md after the PreToolUse hook nudges it
# to wrap up). Resets when the signal disappears, which Mithril does if the
# bid is re-allocated.
set -u

SIG="${MITHRIL_SIGNAL_FILE:-/opt/mithril/MITHRIL_SIGNAL.yml}"
CTR="${CONTAINER_NAME:?CONTAINER_NAME must be set}"
TAG="${RESUME_TAG:-claude-container:resume}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-30}"

# Sudo because the docker socket's group is the host's `docker` group, which
# the in-container user is not a member of. The image grants NOPASSWD sudo to
# the build user.
DOCKER="sudo -n docker"

log() { echo "[mithril-watch] $(date -Iseconds) $*"; }

snapshot_active=0
last_snapshot=0

while :; do
  if [ -f "$SIG" ] && grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG" 2>/dev/null; then
    if [ "$snapshot_active" = 0 ]; then
      log "signal detected:"
      cat "$SIG" 2>/dev/null | sed 's/^/[mithril-watch]   /'
      snapshot_active=1
      last_snapshot=0
    fi
    now=$(date +%s)
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
