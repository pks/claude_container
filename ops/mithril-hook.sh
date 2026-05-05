#!/bin/bash
# Claude Code PreToolUse hook. Fires before every tool call. When the Mithril
# spot-interruption signal is present and the agent has not yet acknowledged
# it, injects a `additionalContext` payload telling the agent to commit, write
# a STATUS.md, ack, and exit. After the agent touches /workspace/.shutdown-acked
# the hook stays quiet so it does not nag during graceful wind-down.
set -u

SIG="${MITHRIL_SIGNAL_FILE:-/opt/mithril/MITHRIL_SIGNAL.yml}"
ACK="${SHUTDOWN_ACK_FILE:-/workspace/.shutdown-acked}"

[ -f "$SIG" ] || exit 0
grep -qE 'STATUS_(PREEMPTING|RELOCATING)' "$SIG" 2>/dev/null || exit 0
[ -f "$ACK" ] && exit 0

end_time=$(awk -F': ' '/^end_time:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SIG")
status=$(awk -F': ' '/^instance_status:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$SIG")

read -r -d '' MSG <<EOF || true
MITHRIL SPOT INTERRUPTION SIGNALED (${status}). The node will terminate at ${end_time} (~5 minutes from when this signal first appeared). Stop launching new long-running jobs (training, evals, etc). Commit any pending changes to git with a clear message. Write a brief /workspace/STATUS.md summarizing in-flight work and what the next agent should do to resume. Then run \`touch /workspace/.shutdown-acked\` and exit cleanly. The container filesystem is being snapshotted via docker commit and tagged claude-container:resume, but in-flight processes will be killed when the node goes down. A resumed agent on the new node will receive --continue plus a resume prompt.
EOF

# JSON-escape the message
esc=$(printf '%s' "$MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

cat <<EOF
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": ${esc}}}
EOF
