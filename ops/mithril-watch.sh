#!/bin/bash
# Polls /opt/mithril/MITHRIL_SIGNAL.yml for spot-interruption notices. While
# the signal is active and the agent has not yet acked via
# /workspace/.shutdown-acked, SIGINTs PID 1 every INTERRUPT_INTERVAL seconds
# so the agent breaks out of any in-flight long-running tool call (e.g. a
# multi-hour training run). The PreToolUse hook (mithril-hook.sh) delivers
# the shutdown context on the agent's next tool call after the interrupt;
# SIGINT just guarantees that next tool call happens promptly.
#
# Data persistence is handled by host bind mounts (/workspace,
# ~/.claude/projects, ~/.pi/agent/sessions), not by this watcher.
#
# Skips the interrupt when PID 1 isn't an agent (e.g. the `bash` profile
# drops you into an interactive shell — we shouldn't SIGINT the user).
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
  if [ -f "$SIG" ] && grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG" 2>/dev/null; then
    if [ "$active" = 0 ]; then
      log "signal detected:"
      cat "$SIG" 2>/dev/null | sed 's/^/[mithril-watch]   /'
      active=1
      last_interrupt=0
    fi
    if [ "$INTERRUPT_PID1" = 1 ] && [ ! -f "$ACK" ]; then
      now=$(date +%s)
      if [ $((now - last_interrupt)) -ge "$INTERRUPT_INTERVAL" ]; then
        log "SIGINT -> PID 1 ($pid1_comm) to interrupt in-flight work"
        kill -INT 1 || log "kill -INT 1 failed (rc=$?)"
        last_interrupt=$now
      fi
    fi
  else
    if [ "$active" = 1 ]; then
      log "signal cleared (bid restored?)"
      active=0
    fi
  fi
  sleep "$POLL_INTERVAL"
done
