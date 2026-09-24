#!/bin/bash
# Claude Code PreToolUse hook. While preemption is signaled and the agent
# hasn't acked, emits additionalContext nudging it to commit + STATUS.md +
# ack + exit. Stays quiet after ack so it doesn't nag.
set -u

SIG="${MITHRIL_SIGNAL_FILE:-/opt/mithril/MITHRIL_SIGNAL.yml}"
ACK="${SHUTDOWN_ACK_FILE:-/workspace/.shutdown-acked}"

[ -f "$SIG" ] || exit 0
grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG" || exit 0
[ -f "$ACK" ] && exit 0

END_TIME=$(awk -F': ' '/^end_time:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SIG")
STATUS=$(awk -F': ' '/^instance_status:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SIG")
HOME_PATH="${HOME:-/home/ubuntu}"

# Shared with pi-extensions/mithril/index.ts via {{STATUS}} / {{END_TIME}} /
# {{HOME_PATH}} placeholders. Mustache-style avoids shell evaluation entirely.
TEMPLATE="${MITHRIL_NUDGE_TEMPLATE:-/usr/local/share/mithril-nudge.txt}"
if [ -f "$TEMPLATE" ]; then
  msg=$(sed \
    -e "s|{{STATUS}}|$STATUS|g" \
    -e "s|{{END_TIME}}|$END_TIME|g" \
    -e "s|{{HOME_PATH}}|$HOME_PATH|g" \
    "$TEMPLATE")
else
  msg="MITHRIL SPOT INTERRUPTION SIGNALED ($STATUS). Node terminates at $END_TIME. Commit + STATUS.md + ack + exit."
fi

jq -nRc --arg msg "$msg" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $msg}}'
