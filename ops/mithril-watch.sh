#!/bin/bash
# Polls /opt/mithril/MITHRIL_SIGNAL.yml. While preemption is signaled and the
# agent hasn't acked via /workspace/.shutdown-acked:
#   1. First ESCALATE_AFTER (default 3) iterations: SIGINT PID 1 every
#      INTERRUPT_INTERVAL seconds. SIGINT aborts the agent's foreground tool
#      call so it gets back to its loop and sees the preemption nudge.
#   2. After that: escalate to SIGTERM PID 1 to force the container down.
#      The agent has had ~3 grace periods to commit + ack + exit; if it
#      hasn't, we'd rather lose the in-progress turn than run out the
#      ~5-minute termination window.
# Skips when PID 1 is a shell (bash profile).
#
# Persistence is handled by host bind mounts in run.sh, not here.
set -u

SIG="${MITHRIL_SIGNAL_FILE:-/opt/mithril/MITHRIL_SIGNAL.yml}"
ACK="${SHUTDOWN_ACK_FILE:-/workspace/.shutdown-acked}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
INTERRUPT_INTERVAL="${INTERRUPT_INTERVAL:-45}"
ESCALATE_AFTER="${ESCALATE_AFTER:-3}"

log() { echo "[mithril-watch] $(date -Iseconds) $*"; }

pid1_comm=$(cat /proc/1/comm 2>/dev/null || echo unknown)
case "$pid1_comm" in
  bash|sh|zsh) INTERRUPT_PID1=0; log "PID 1 is $pid1_comm; SIGINT disabled" ;;
  *)           INTERRUPT_PID1=1 ;;
esac

active=0
last_interrupt=0
int_count=0
escalated=0

while :; do
  if [ -f "$SIG" ] && grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG"; then
    if [ "$active" = 0 ]; then
      log "signal detected:"
      sed 's/^/[mithril-watch]   /' "$SIG"
      active=1
      last_interrupt=0
      int_count=0
      escalated=0
    fi
    if [ "$INTERRUPT_PID1" = 1 ] && [ ! -f "$ACK" ]; then
      now=$(date +%s)
      if [ $((now - last_interrupt)) -ge "$INTERRUPT_INTERVAL" ]; then
        int_count=$((int_count + 1))
        if [ "$int_count" -le "$ESCALATE_AFTER" ]; then
          log "SIGINT -> PID 1 ($pid1_comm) [$int_count/$ESCALATE_AFTER]"
          kill -INT 1 || log "kill -INT 1 failed (rc=$?)"
        else
          if [ "$escalated" = 0 ]; then
            log "ESCALATE: $ESCALATE_AFTER SIGINTs sent without ack; switching to SIGTERM"
            escalated=1
          fi
          log "SIGTERM -> PID 1 ($pid1_comm)"
          kill -TERM 1 || log "kill -TERM 1 failed (rc=$?)"
        fi
        last_interrupt=$now
      fi
    fi
  elif [ "$active" = 1 ]; then
    log "signal cleared (bid restored?)"
    active=0
    int_count=0
    escalated=0
  fi
  sleep "$POLL_INTERVAL"
done
