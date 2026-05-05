#!/bin/bash
set -eu

PROFILE="${1:-claude}"
GPU="${2:-all}"

case "$GPU" in
  all) GPU_FLAG=(--gpus all) ;;
  *)   GPU_FLAG=(--gpus "device=$GPU") ;;
esac

# Persistent host state. /workspace, ~/.claude/projects (Claude Code session
# logs), and ~/.pi/agent/sessions (pi session logs) are bind-mounted from
# here so they survive container restarts and same-node-type Mithril spot
# relocations (which preserve the root disk). Override with DIFFUSEMT_STATE.
STATE_DIR="${DIFFUSEMT_STATE:-$PWD/state}"
mkdir -p "$STATE_DIR"/{workspace,claude-projects,pi-sessions}

# Seed the workspace bind mount from the image on first run. Subsequent runs
# pick up the agent's accumulated state. To start over from a clean image
# workspace: rm -rf $STATE_DIR/workspace and re-run.
if [ -z "$(ls -A "$STATE_DIR/workspace" 2>/dev/null)" ]; then
  echo "run.sh: seeding $STATE_DIR/workspace from claude-container image..." >&2
  cid=$(docker create claude-container)
  docker cp "$cid:/workspace/." "$STATE_DIR/workspace/"
  docker rm "$cid" >/dev/null
fi

# Resume only when there's actually a session for the agent we're launching.
HAS_CLAUDE_SESSION=0
HAS_PI_SESSION=0
[ -n "$(find "$STATE_DIR/claude-projects" -name '*.jsonl' -print -quit 2>/dev/null)" ] \
  && HAS_CLAUDE_SESSION=1
[ -n "$(find "$STATE_DIR/pi-sessions" -name '*.jsonl' -print -quit 2>/dev/null)" ] \
  && HAS_PI_SESSION=1

MOUNTS=(
  -v "$STATE_DIR/workspace:/workspace"
  -v "$STATE_DIR/claude-projects:/home/ubuntu/.claude/projects"
  -v "$STATE_DIR/pi-sessions:/home/ubuntu/.pi/agent/sessions"
)

# Reuse host Claude Code auth if available. Layered over the claude-projects
# bind mount above (single-file mount wins for that one file).
[ -f ~/.claude/.credentials.json ] \
  && MOUNTS+=(-v ~/.claude/.credentials.json:/home/ubuntu/.claude/.credentials.json)
[ -f ~/.claude.json ] \
  && MOUNTS+=(-v ~/.claude.json:/home/ubuntu/.claude.json)

# Mithril spot-interruption signal file (read-only). The in-container watcher
# polls it and SIGINTs the agent so it breaks out of long-running tool calls.
[ -d /opt/mithril ] \
  && MOUNTS+=(-v /opt/mithril:/opt/mithril:ro)

ENVS=(
  -e CLAUDE_CODE_THEME=dark
  -e CLAUDE_CODE_ACCEPT_TOS=yes
  -e CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=yes
  -e CLAUDE_CODE_SKIP_TRUST_SCREEN=1
)

PROMPT='/skill:caveman lite\ncarry out doc/PLAN.md'
RESUME_PROMPT='You were just preempted by a Mithril spot interruption and resumed on a new instance. /workspace and your prior session are bind-mounted from host-persistent storage, so they survived intact. Read /workspace/STATUS.md if present, check `git log` and the working-tree state, then continue carrying out doc/PLAN.md from where you left off. Once you have re-established context, run `rm -f /workspace/.shutdown-acked` so the next preemption is handled cleanly.'

# Decide whether the chosen profile has a session to resume.
case "$PROFILE" in
  claude)         RESUMING="$HAS_CLAUDE_SESSION" ;;
  pi-ollama|pi-azure|pi-or) RESUMING="$HAS_PI_SESSION" ;;
  *)              RESUMING=0 ;;
esac

# `claude --continue` and `pi -c` both resume the most recent session in the
# current cwd; sessions live in the bind-mounted state dirs.
if [ "$RESUMING" = 1 ]; then
  CLAUDE_RESUME=(--continue)
  PI_RESUME=(-c)
  EFFECTIVE_PROMPT="$RESUME_PROMPT"
else
  CLAUDE_RESUME=()
  PI_RESUME=()
  EFFECTIVE_PROMPT="$PROMPT"
fi

case "$PROFILE" in
  claude)
    ENTRYPOINT=claude
    ARGS=("${CLAUDE_RESUME[@]}" --dangerously-skip-permissions --model claude-opus-4-6 --effort max "$EFFECTIVE_PROMPT")
    ;;
  pi-ollama)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    ARGS=("${PI_RESUME[@]}" --provider ollama --model qwen3.6:35b --thinking max "$EFFECTIVE_PROMPT")
    ;;
  pi-azure)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    : "${AZURE_BASE_URL:?AZURE_BASE_URL must be set for pi-azure}"
    ENVS+=(-e "AZURE_BASE_URL=$AZURE_BASE_URL")
    if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
      echo "pi-azure: set only one of ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      ENVS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
      ARGS=("${PI_RESUME[@]}" --provider anthropic --model "${PI_MODEL:-claude-opus-4-7}" --thinking xhigh "$EFFECTIVE_PROMPT")
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
      ENVS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
      ARGS=("${PI_RESUME[@]}" --provider openai --model "${PI_MODEL:-gpt-5}" --thinking high "$EFFECTIVE_PROMPT")
    else
      echo "pi-azure: set ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    fi
    ;;
  pi-or)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY must be set for pi-or}"
    OR_PROMPT="$EFFECTIVE_PROMPT"
    [ "$RESUMING" = 0 ] && OR_PROMPT='/skill:caveman\ncarry out doc/PLAN.md'
    ARGS=("${PI_RESUME[@]}" --provider openrouter --api-key "$OPENROUTER_API_KEY" --model moonshotai/kimi-k2.6 --thinking high "$OR_PROMPT")
    ;;
  bash)
    ENTRYPOINT=bash
    ARGS=()
    ;;
  *)
    echo "usage: $0 {claude|pi-ollama|pi-azure|pi-or|bash} [gpu-id|all]" >&2
    exit 1
    ;;
esac

exec docker run \
  -it \
  --rm \
  "${GPU_FLAG[@]}" \
  --network host \
  -u "$(id -u):$(id -g)" \
  -w /workspace \
  --entrypoint /usr/local/bin/entrypoint.sh \
  "${MOUNTS[@]}" \
  "${ENVS[@]}" \
  claude-container \
  "$ENTRYPOINT" "${ARGS[@]}"
