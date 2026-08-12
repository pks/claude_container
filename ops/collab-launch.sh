#!/bin/bash
# collab-launch.sh — launch the collaborative-agents experiment (per host).
#
# Topology: 4 agents, 1/GPU, across titan (2× TITAN RTX) + titan2 (2× A6000).
# Run this ONCE PER HOST with that host's agent list. Sharing = a git-daemon on the
# git host (titan) serving collab_v0.git with anonymous receive-pack (LAN-only, no ssh
# keys). Each agent gets its own working clone bind-mounted at /collab; collab-{post,
# say,view} (baked in the image) do git inside the container over the git:// origin.
#
# Each agent runs in its own tmux session (its own pty → pi's TUI works; 4 can't share
# one terminal), wall-clock-capped with SIGINT-then-kill (agent flushes its deliverable).
#
#   # 0. once, on the git host (titan): serve the bare repo
#   ops/collab-launch.sh daemon
#
#   # 1. on titan:
#   ARM=collab GIT_URL=git://10.10.20.21/collab_v0.git WALL_HOURS=12 PROFILE=pi-azure \
#     ops/collab-launch.sh agent-0:0:TITAN agent-1:1:TITAN
#
#   # 2. on titan2 (reach titan over Tailscale):
#   ARM=collab GIT_URL=git://titan2.tailcd9e.ts.net/collab_v0.git WALL_HOURS=12 PROFILE=pi-openai \
#     ops/collab-launch.sh agent-2:0:A6000 agent-3:1:A6000
#     # NOTE: GIT_URL host must be TITAN's address as seen from THIS host.
#
#   # solo control arm — same, but ARM=solo (no /collab, plan stripped of the protocol):
#   ARM=solo WALL_HOURS=12 ops/collab-launch.sh agent-0:0:TITAN agent-1:1:TITAN
#
# Attach to an agent:  tmux attach -t collab-agent-0     List:  tmux ls
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

BARE="${COLLAB_BARE:-$HOME/exp/diffusemt_meta/collab_v0.git}"
BASE_PATH="$(dirname "$BARE")"                       # git-daemon base-path
IMAGE="${IMAGE:-mtbench-container}"
ARM="${ARM:-collab}"                                 # collab | solo
PROFILE="${PROFILE:-pi-azure}"
WALL_HOURS="${WALL_HOURS:-12}"
GRACE="${GRACE:-120}"                                # SIGINT→SIGKILL grace at the cap
STAGGER="${STAGGER:-1200}"                           # seconds between agent starts (cold-start anti-dup)
STATE_BASE="${STATE_BASE:-$REPO/collab_state}"
GIT_URL="${GIT_URL:-git://127.0.0.1/collab_v0.git}"  # collab arm only

# ---- daemon mode: serve the bare repo (run once on titan) --------------------
if [ "${1:-}" = "daemon" ]; then
  [ -d "$BARE" ] || { echo "no bare repo at $BARE (git init --bare it first)" >&2; exit 1; }
  echo "collab: git-daemon serving $BASE_PATH (anonymous receive-pack, LAN)" >&2
  echo "  agents clone git://<this-host>/$(basename "$BARE")" >&2
  exec git daemon --verbose --reuseaddr --base-path="$BASE_PATH" \
       --export-all --enable=receive-pack "$BASE_PATH"
fi

[ "$#" -ge 1 ] || { echo "usage: $0 daemon | <agent-id:gpu:gpuname> ..." >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux required" >&2; exit 1; }

# ---- stage the plan (collab: full; solo: strip the Collaborate section) ------
# `make seed` ships plan/PLAN.md → workspace/doc/PLAN.md. All agents this arm share it.
mkdir -p plan
if [ "$ARM" = solo ]; then
  awk '/^## Collaborate/{skip=1} /^## Deliverable/{skip=0} !skip' collab/PLAN-collab.md > plan/PLAN.md
  echo "collab-launch: staged SOLO plan (Collaborate section stripped)" >&2
else
  cp collab/PLAN-collab.md plan/PLAN.md
  echo "collab-launch: staged COLLAB plan" >&2
fi

i=0
for spec in "$@"; do
  IFS=: read -r AGENT GPU GPUNAME <<< "$spec"
  [ -n "$AGENT" ] && [ -n "$GPU" ] || { echo "bad spec '$spec' (want id:gpu:gpuname)" >&2; exit 1; }
  STATE_DIR="$STATE_BASE/$AGENT"
  echo "=== $AGENT  gpu=$GPU ($GPUNAME)  arm=$ARM  state=$STATE_DIR ===" >&2

  # seed the per-agent state dir if fresh (copies /workspace+/home from image + the plan)
  if [ ! -d "$STATE_DIR/workspace" ] || [ ! -d "$STATE_DIR/home" ]; then
    make -s seed STATE_DIR="$STATE_DIR" >&2
  fi

  # collab arm: give this agent its own working clone (bind-mounted at /collab)
  COLLAB_ENV=()
  if [ "$ARM" = collab ]; then
    CLONE="$STATE_DIR/collab"
    if [ ! -d "$CLONE/.git" ]; then
      git clone -q "$GIT_URL" "$CLONE"
    fi
    git -C "$CLONE" config user.name  "$AGENT"
    git -C "$CLONE" config user.email "$AGENT@collab"
    git -C "$CLONE" config pull.rebase true
    COLLAB_ENV=(COLLAB_HOST_DIR="$CLONE" COLLAB_AGENT="$AGENT" COLLAB_GPU="$GPUNAME")
  fi

  # each agent in its own tmux session (own pty). Wall-clock cap: SIGINT to flush the
  # deliverable, SIGKILL after grace. --foreground so the TTY passes through to pi's TUI.
  SESS="collab-$AGENT"
  tmux kill-session -t "$SESS" 2>/dev/null || true
  tmux new-session -d -s "$SESS" \
    "cd '$REPO' && STATE_DIR='$STATE_DIR' GPU='$GPU' IMAGE='$IMAGE' ${COLLAB_ENV[*]} \
       timeout --foreground --signal=SIGINT --kill-after='${GRACE}' '${WALL_HOURS}h' \
       ./run.sh '$PROFILE' 2>&1 | tee -a '$STATE_DIR/launch.log'; \
     echo '[collab] $AGENT exited rc='\$? ; sleep 3600"
  echo "collab-launch: $AGENT up in tmux '$SESS' (attach: tmux attach -t $SESS)" >&2

  i=$((i+1))
  # stagger starts so later agents see early leaderboard entries (cold-start anti-dup)
  if [ "$ARM" = collab ] && [ "$i" -lt "$#" ] && [ "$STAGGER" -gt 0 ]; then
    echo "collab-launch: staggering ${STAGGER}s before next agent ..." >&2
    sleep "$STAGGER"
  fi
done

echo "collab-launch: launched $# agent(s) on $(hostname). tmux ls to see them." >&2
