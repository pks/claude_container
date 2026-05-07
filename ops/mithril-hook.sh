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

end_time=$(awk -F': ' '/^end_time:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SIG")
status=$(awk -F': ' '/^instance_status:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SIG")

msg="MITHRIL SPOT INTERRUPTION SIGNALED ($status). Node terminates at $end_time. Stop launching new long-running jobs. Commit pending changes to git. Write /workspace/STATUS.md summarizing in-flight work and what to resume next. touch /workspace/.shutdown-acked and exit. /workspace and /home/ubuntu are bind-mounted from host-persistent storage so they survive; only in-flight processes will be killed. The next run picks up via --continue with a resume prompt."

jq -nRc --arg msg "$msg" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $msg}}'
