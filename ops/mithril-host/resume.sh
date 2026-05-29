#!/bin/bash
# Start the agent inside a detached tmux session so it has a tty (docker run -it
# in run.sh requires one) and so the operator can `tmux attach -t diffusemt` to
# watch. Idempotent: if the session already exists, leave it alone — that way
# `systemctl restart diffusemt-resume` doesn't kill an in-flight run.
#
# Driven by env (PROFILE, GPU, TMUX_SESSION) from the unit file +
# /home/ubuntu/exp/.diffusemt-resume.env (optional override).
set -euo pipefail

SESSION="${TMUX_SESSION:-diffusemt}"
PROFILE="${PROFILE:-claude}"
GPU="${GPU:-all}"
REPO="${REPO:-/home/ubuntu/exp/diffusemt}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' already running; leaving as-is" >&2
  exit 0
fi

# `exec bash` after make exits keeps the pane alive so you can attach and
# inspect the tail of the agent's output instead of losing it to a closed pane.
tmux new-session -d -s "$SESSION" -c "$REPO" \
  "PROFILE='$PROFILE' GPU='$GPU' make run; exec bash"
