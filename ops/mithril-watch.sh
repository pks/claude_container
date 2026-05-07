#!/bin/bash
# Polls /opt/mithril/MITHRIL_SIGNAL.yml. While preemption is signaled and the
# agent hasn't acked via /workspace/.shutdown-acked, SIGINTs PID 1 every
# INTERRUPT_INTERVAL seconds so the agent breaks out of any in-flight
# long-running tool call and sees the PreToolUse hook's shutdown context on
# its next turn. Skips when PID 1 is a shell (bash profile).
#
# Persistence is handled by host bind mounts in run.sh, not here.
set -u

SIG="${MITHRIL_SIGNAL_FILE:-/opt/mithril/MITHRIL_SIGNAL.yml}"
ACK="${SHUTDOWN_ACK_FILE:-/workspace/.shutdown-acked}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
INTERRUPT_INTERVAL="${INTERRUPT_INTERVAL:-45}"

log() { echo "[mithril-watch] $(date -Iseconds) $*"; }

pid1_comm=$(cat /proc/1/comm 2>/dev/null || echo unknown)
case "$pid1_comm" in
  bash|sh|zsh) INTERRUPT_PID1=0; log "PID 1 is $pid1_comm; SIGINT disabled" ;;
  *)           INTERRUPT_PID1=1 ;;
esac

active=0
last_interrupt=0

while :; do
  if [ -f "$SIG" ] && grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG"; then
    if [ "$active" = 0 ]; then
      log "signal detected:"
      sed 's/^/[mithril-watch]   /' "$SIG"
      active=1
      last_interrupt=0
    fi
    if [ "$INTERRUPT_PID1" = 1 ] && [ ! -f "$ACK" ]; then
      now=$(date +%s)
      if [ $((now - last_interrupt)) -ge "$INTERRUPT_INTERVAL" ]; then
        log "SIGINT -> PID 1 ($pid1_comm)"
        kill -INT 1 || log "kill -INT 1 failed (rc=$?)"
        last_interrupt=$now
      fi
    fi
  elif [ "$active" = 1 ]; then
    log "signal cleared (bid restored?)"
    active=0
  fi
  sleep "$POLL_INTERVAL"
done
