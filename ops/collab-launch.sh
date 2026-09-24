#!/bin/bash
# collab-launch.sh — launch the collaborative-agents experiment (per host).
#
# Topology: 1 agent/GPU, any count — titan has 2× TITAN RTX, titan2 has 2× A6000, so
# the full cohort is 4, but 2 (one host) or 1 (a pilot) work too; the cohort size is
# rendered into the plan from the agent list, not hardcoded. Cohort spanning both hosts:
# pass COHORT="agent-0 agent-1 agent-2 agent-3" on each host so the roster is accurate.
# Run this ONCE PER HOST with that host's agent list. Sharing = a git-daemon on the
# git host (titan) serving collab_v0.git with anonymous receive-pack (LAN-only, no ssh
# keys). Each agent gets its own working clone bind-mounted at /collab; collab-{post,
# say,view} (baked in the image) do git inside the container over the git:// origin.
#
# Each agent runs in its own tmux session (its own pty → pi's TUI works; 4 can't share
# one terminal), optionally under a wall-clock backstop with SIGINT-then-kill so the agent
# flushes its deliverable (WALL_HOURS, default 72 h; `none` for no cap).
#
#   # 0. once, on the git host (titan): serve the bare repo
#   ops/collab-launch.sh daemon
#
# PROFILE=claude runs Claude Code on the HOST SUBSCRIPTION — no API key, no per-token
# cost. run.sh copies ~/.claude/.credentials.json + ~/.claude.json into each agent's
# own $STATE_DIR/home (never bind-mounts them: concurrent agents both write those files).
# Log in once per host (`claude`) before launching. Note the subscription's rate limits
# are shared by every concurrent agent — STAGGER helps, throttling is still expected.
#
# For pi profiles, vendor is chosen INSIDE pi-azure by which key is exported:
# ANTHROPIC_API_KEY → Claude (default PI_MODEL=claude-opus-5); OPENAI_API_KEY
# → OpenAI/Azure (default gpt-5.6-sol). There is no separate pi-openai profile.
# Set exactly one key (plus AZURE_BASE_URL) in the launching shell or .env.
#
#   # 1. on titan — Claude Code + opus-5 on the subscription:
#   ARM=collab PROFILE=claude IMAGE=collab-container WALL_HOURS=none \
#     GIT_URL=git://10.10.20.21/collab_v0.git \
#     COHORT="agent-0 agent-1 agent-2 agent-3" \
#     ops/collab-launch.sh agent-0:0:TITAN agent-1:1:TITAN
#
#   # 2. on titan2 — same, pointing at titan's LAN address for the git host:
#   ARM=collab PROFILE=claude IMAGE=collab-container WALL_HOURS=none \
#     GIT_URL=git://10.10.20.21/collab_v0.git \
#     COHORT="agent-0 agent-1 agent-2 agent-3" \
#     ops/collab-launch.sh agent-2:0:A6000 agent-3:1:A6000
#     # COHORT = the WHOLE cohort (both hosts), same value on each; it is what the plan
#     # tells each agent about its peers. Omit it and the plan only names this host's two.
#     # NOTE: GIT_URL host = the git host (titan)'s address as seen from THIS host.
#     # titan=10.10.20.21, titan2=10.10.20.24 on the LAN. The Tailscale name
#     # titan2.tailcd9e.ts.net refuses :22 — use the LAN addresses.
#
#   # a pi lane instead (metered API key):
#   ARM=collab PROFILE=pi-azure ANTHROPIC_API_KEY=... AZURE_BASE_URL=... \
#     ops/collab-launch.sh agent-0:0:TITAN
#
#   # solo control arm — same, but ARM=solo (no /collab; plan = the task file alone):
#   ARM=solo WALL_HOURS=none ops/collab-launch.sh agent-0:0:TITAN agent-1:1:TITAN
#
#   # WALL_HOURS: hours of backstop cap, or `none` for no cap (default 72). The diffusion
#   # task is run to a dev plateau, so the cap is a safety net, not the budget — but keep
#   # the two ARMs on the same setting or the comparison is not matched.
#
# The plan the agents read is assembled here: TASK_DOC (default $COLLAB_DIR/TASK-diffusion.md)
# for both arms, plus OVERLAY_DOC (default $COLLAB_DIR/PLAN-collab.md — the collaboration
# protocol) appended for the collab arm only. Swap the task with TASK_DOC=… ; the collab
# machinery is arm-side and needs no edit.
#
# Attach to an agent:  tmux attach -t collab-agent-0     List:  tmux ls
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

BARE="${COLLAB_BARE:-$HOME/exp/diffusemt_meta/collab_v0.git}"
BASE_PATH="$(dirname "$BARE")"                       # git-daemon base-path
# collab-container, not mtbench-container: this branch's image also carries Claude
# Code + the collab tools, and rebuilding under the bench name would overwrite the
# pi-only bench image whose build timestamp is provenance in the study repo's
# bench/RESULTS-runs.md.
IMAGE="${IMAGE:-collab-container}"
ARM="${ARM:-collab}"                                 # collab | solo
PROFILE="${PROFILE:-claude}"
# Wall clock. The diffusion setting is run to a dev plateau, not to a clock, so the cap is
# now a long backstop rather than the budget: 72 h by default, WALL_HOURS=none to remove it
# entirely (the agent then runs until it exits, the container is stopped, or the host reboots).
# Cost scales with wall time, and an idle-waiting agent is the expensive kind — long training
# sleeps blow past the provider's prompt-cache TTL, which is what doubled agent-0's spend in
# the pilot at ~0 output. Poll in short intervals; don't sleep for half an hour.
WALL_HOURS="${WALL_HOURS:-72}"
GRACE="${GRACE:-120}"                                # SIGINT→SIGKILL grace at the cap
case "$WALL_HOURS" in
  none|None|NONE|0)
    TIMEOUT_CMD=()
    echo "collab-launch: no wall-clock cap (WALL_HOURS=$WALL_HOURS) — agents run until stopped" >&2 ;;
  *[!0-9.]*|"")
    echo "collab-launch: WALL_HOURS='$WALL_HOURS' is neither a number of hours nor 'none'" >&2
    exit 1 ;;
  *)
    TIMEOUT_CMD=(timeout --foreground --signal=SIGINT --kill-after="$GRACE" "${WALL_HOURS}h") ;;
esac
STAGGER="${STAGGER:-1200}"                           # seconds between agent starts (cold-start anti-dup)
STATE_BASE="${STATE_BASE:-$REPO/collab_state}"
GIT_URL="${GIT_URL:-git://127.0.0.1/collab_v0.git}"  # collab arm only

# ---- daemon mode: serve the bare repo (run once on titan) --------------------
# SECURITY: --export-all --enable=receive-pack = anonymous, unauthenticated
# WRITE to every repo under base-path. With no --listen it binds 0.0.0.0 (all
# interfaces: LAN *and* Tailscale). Fine only for a throwaway LAN experiment.
# To restrict, set DAEMON_LISTEN to the single trusted IP the agents reach the
# host on (e.g. the Tailscale addr), and stop the daemon when the run ends.
if [ "${1:-}" = "daemon" ]; then
  [ -d "$BARE" ] || { echo "no bare repo at $BARE (git init --bare it first)" >&2; exit 1; }
  LISTEN_ARG=()
  [ -n "${DAEMON_LISTEN:-}" ] && LISTEN_ARG=(--listen="$DAEMON_LISTEN")
  echo "collab: git-daemon serving $BASE_PATH (anonymous receive-pack, ${DAEMON_LISTEN:-0.0.0.0})" >&2
  echo "  agents clone git://<this-host>/$(basename "$BARE")" >&2
  exec git daemon --verbose --reuseaddr --base-path="$BASE_PATH" "${LISTEN_ARG[@]}" \
       --export-all --enable=receive-pack "$BASE_PATH"
fi

[ "$#" -ge 1 ] || { echo "usage: $0 daemon | <agent-id:gpu:gpuname> ..." >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux required" >&2; exit 1; }

# ---- cohort roster: substituted into the plan --------------------------------
# The cohort size is NOT hardcoded in the plan (it used to say "four", which lies to
# any run that isn't 4 agents — the pilot ran 2). This script runs once per host, so
# "$@" only names THIS host's agents; when the cohort spans hosts, set COHORT to every
# agent id in the run (same value on both hosts) so the roster the agents read is real.
#   COHORT="agent-0 agent-1 agent-2 agent-3"
if [ -n "${COHORT:-}" ]; then
  read -r -a COHORT_IDS <<< "$COHORT"
else
  COHORT_IDS=()
  for spec in "$@"; do COHORT_IDS+=("${spec%%:*}"); done
fi
N_AGENTS="${#COHORT_IDS[@]}"
ROSTER="$(printf '%s, ' "${COHORT_IDS[@]}")"; ROSTER="${ROSTER%, }"

# ---- stage the plan = TASK + (collab arm only) the collaboration overlay -----
# `make seed` ships plan/PLAN.md → workspace/doc/PLAN.md. All agents this arm share it.
#
# The task and the collaboration protocol live in SEPARATE files, so the two arms differ
# by concatenation rather than by text surgery: solo gets the task file verbatim (no
# tokens, no peers, nothing to strip), collab gets task + overlay. Swap the task without
# touching the collab machinery via TASK_DOC.
# These files are NOT in this repo -- they live in the study repo's collab/, since
# they define the experiment rather than the machinery. COLLAB_DIR defaults to a
# sibling checkout; override it if the study repo is elsewhere.
COLLAB_DIR="${COLLAB_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/collab}"
TASK_DOC="${TASK_DOC:-$COLLAB_DIR/TASK-diffusion.md}"
OVERLAY_DOC="${OVERLAY_DOC:-$COLLAB_DIR/PLAN-collab.md}"
[ -f "$TASK_DOC" ] || {
  echo "collab-launch: TASK_DOC '$TASK_DOC' not found" >&2
  echo "  Task files live in the study repo (diffusemt_meta/collab)." >&2
  echo "  Point at it with COLLAB_DIR=/path/to/diffusemt_meta/collab" >&2
  exit 1; }
[ "$ARM" = solo ] || [ -f "$OVERLAY_DOC" ] || {
  echo "collab-launch: OVERLAY_DOC '$OVERLAY_DOC' not found" >&2; exit 1; }

mkdir -p plan
if [ "$ARM" = solo ]; then
  COHORT_LINE=""    # unused: the solo arm gets the task file and nothing appended
elif [ "$N_AGENTS" -ge 2 ]; then
  COHORT_LINE="**You are one of $N_AGENTS agents working the same problem at once ($ROSTER), and you can share results, ideas, and code with the others.**"
else
  # Collab arm with a cohort of 1: the blackboard works but has nobody on the far side.
  # Don't claim a peer count — say what is true and let the board show who shows up.
  COHORT_LINE="**You share a blackboard with any peers working this same problem, and you can share results, ideas, and code with them.**"
  echo "collab-launch: WARNING collab arm with a cohort of 1 ($ROSTER) — no peers named in the plan." >&2
  echo "  If peers run on another host, set COHORT=\"agent-0 agent-1 ...\" (all of them) on every host." >&2
fi

# Substitute by index, not gsub/sed: COHORT_LINE contains `*` and could contain `&`.
render_overlay() {
  awk -v line="$COHORT_LINE" -v tok='{{COHORT_LINE}}' '
    { i = index($0, tok)
      if (i) $0 = substr($0, 1, i-1) line substr($0, i + length(tok))
      print }' "$OVERLAY_DOC"
}
if [ "$ARM" = solo ]; then
  cp "$TASK_DOC" plan/PLAN.md
  echo "collab-launch: staged SOLO plan ($TASK_DOC, no overlay)" >&2
else
  { cat "$TASK_DOC"; echo; render_overlay; } > plan/PLAN.md
  echo "collab-launch: staged COLLAB plan ($TASK_DOC + $OVERLAY_DOC; cohort of $N_AGENTS: $ROSTER)" >&2
fi
if grep -q '{{' plan/PLAN.md; then
  echo "collab-launch: plan still has an unsubstituted {{token}} — refusing to seed:" >&2
  grep -n '{{' plan/PLAN.md >&2
  exit 1
fi
# The control arm must not learn peers exist. It ships $TASK_DOC verbatim, so the only way
# that leaks is a collab reference written into the task file itself — check, don't assume.
if [ "$ARM" = solo ] && grep -qiE 'collab|blackboard|\bpeers?\b|another agent' plan/PLAN.md; then
  echo "collab-launch: WARNING the SOLO plan mentions collaboration — $TASK_DOC leaks the arm:" >&2
  grep -niE 'collab|blackboard|\bpeers?\b|another agent' plan/PLAN.md >&2
  echo "  Move that text into $OVERLAY_DOC, or the two arms are not matched." >&2
fi

# Host notes → doc/HOST.md. The card the agent gets is power-capped on a schedule (a
# throttled card inflates per-step time ~3-7x) and on titan it is Turing, so no bf16 —
# without this the agent budgets steps against throughput it never gets, which is how
# v5's TITAN run died. One doc PER HOST, each describing only that host's card: the
# agent sees a single GPU, so it is told about a single GPU. Picked by hostname;
# HOST_DOC=/path overrides, HOST_DOC=none skips deliberately.
HOST_DOC="${HOST_DOC:-$REPO/../plan/HOST-$(hostname -s).md}"
if [ "$HOST_DOC" = none ]; then
  echo "collab-launch: no HOST doc staged (HOST_DOC=none)" >&2
elif [ -f "$HOST_DOC" ]; then
  cp "$HOST_DOC" plan/HOST.md
  echo "collab-launch: staged HOST doc from $HOST_DOC" >&2
else
  echo "collab-launch: HOST_DOC $HOST_DOC not found — agents get no hardware notes" >&2
  echo "  This host is $(hostname -s); write plan/HOST-$(hostname -s).md describing ITS card" >&2
  echo "  only, or set HOST_DOC=/path/to/HOST.md, or HOST_DOC=none to accept that." >&2
fi

i=0
for spec in "$@"; do
  IFS=: read -r AGENT GPU GPUNAME <<< "$spec"
  [ -n "$AGENT" ] && [ -n "$GPU" ] || { echo "bad spec '$spec' (want id:gpu:gpuname)" >&2; exit 1; }
  # gpuname is optional in the spec, but the plan tells the agent its card is named in
  # $MTBENCH_GPU — so fill it from the driver rather than shipping an empty promise.
  if [ -z "${GPUNAME:-}" ]; then
    GPUNAME="$(nvidia-smi -i "$GPU" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    [ -n "$GPUNAME" ] && echo "collab-launch: $AGENT gpuname omitted — using '$GPUNAME' from nvidia-smi" >&2
  fi
  STATE_DIR="$STATE_BASE/$AGENT"
  echo "=== $AGENT  gpu=$GPU ($GPUNAME)  arm=$ARM  state=$STATE_DIR ===" >&2

  # seed the per-agent state dir if fresh (copies /workspace+/home from image + the plan).
  # IMAGE must be forwarded: the Makefile defaults to the bench image, so without it
  # the state dir gets seeded from a different image than run.sh then runs.
  if [ ! -d "$STATE_DIR/workspace" ] || [ ! -d "$STATE_DIR/home" ]; then
    make -s seed STATE_DIR="$STATE_DIR" IMAGE="$IMAGE" >&2
  fi

  # Card name for both arms — the plan tells every agent to check `$MTBENCH_GPU`, so it
  # can't live in the collab-only env block (in the solo arm it would be unset).
  GPU_ENV=(MTBENCH_GPU="$GPUNAME")

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

  # each agent in its own tmux session (own pty). With a cap: SIGINT to flush the deliverable,
  # SIGKILL after grace. --foreground so the TTY passes through to pi's TUI. WALL_HOURS=none
  # leaves TIMEOUT_CMD empty, so run.sh is exec'd directly with no cap.
  SESS="collab-$AGENT"
  tmux kill-session -t "$SESS" 2>/dev/null || true
  tmux new-session -d -s "$SESS" \
    "cd '$REPO' && STATE_DIR='$STATE_DIR' GPU='$GPU' IMAGE='$IMAGE' \
       ${ENV_FILE:+ENV_FILE='$ENV_FILE'} ${PI_MODEL:+PI_MODEL='$PI_MODEL'} \
       ${GPU_ENV[*]} ${COLLAB_ENV[*]} \
       ${TIMEOUT_CMD[*]} \
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
