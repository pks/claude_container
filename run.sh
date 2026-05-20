#!/bin/bash
set -eu

PROFILE="${1:-claude}"
GPU="${2:-all}"

# Parse .env into the host shell (for script-side dispatch like pi-azure
# key selection) and collect the names so we can forward them to the
# container below. Sourced with `.` it would execute as shell code under
# `set -eu` — risky for a secrets file and brittle around values with
# command substitutions or unescaped metacharacters. Each line is treated
# as a literal KEY=VALUE; one surrounding pair of matching quotes is
# stripped, otherwise values are passed through verbatim.
ENV_NAMES_FROM_FILE=()
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$name=$val"
    ENV_NAMES_FROM_FILE+=("$name")
  done < .env
fi

case "$GPU" in
  all) GPU_FLAG=(--gpus all) ;;
  *)   GPU_FLAG=(--gpus "device=$GPU") ;;
esac

# /workspace and /home/ubuntu bind-mount from $STATE_DIR so code, ckpts,
# sessions, plugins, npm-global, etc. survive container exits and same-
# node-type Mithril spot relocations (which preserve the root disk).
# `make seed` populates $STATE_DIR from the image.
IMAGE="${IMAGE:-claude-container}"
STATE_DIR="${STATE_DIR:-$PWD/state}"
if [ ! -d "$STATE_DIR/workspace" ] || [ ! -d "$STATE_DIR/home" ]; then
  echo "run.sh: $STATE_DIR is not seeded — run 'make seed' first" >&2
  exit 1
fi

MOUNTS=(
  -v "$STATE_DIR/workspace:/workspace"
  -v "$STATE_DIR/home:/home/ubuntu"
)

# Host Claude Code auth, layered over the home bind mount above.
[ -f ~/.claude/.credentials.json ] \
  && MOUNTS+=(-v ~/.claude/.credentials.json:/home/ubuntu/.claude/.credentials.json)
[ -f ~/.claude.json ] \
  && MOUNTS+=(-v ~/.claude.json:/home/ubuntu/.claude.json)

# Mithril spot signal — the in-container watcher polls it and SIGINTs the
# agent on preemption.
[ -d /opt/mithril ] \
  && MOUNTS+=(-v /opt/mithril:/opt/mithril:ro)

ENVS=(
  -e CLAUDE_CODE_THEME=dark
  -e CLAUDE_CODE_ACCEPT_TOS=yes
  -e CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=yes
  -e CLAUDE_CODE_SKIP_TRUST_SCREEN=1
)
# Forward every variable declared in .env into the container — adding one
# there auto-propagates without script changes. Names came from the safe
# parser above; `-e VAR` (no value) tells docker to pull from our env.
if [ "${#ENV_NAMES_FROM_FILE[@]}" -gt 0 ]; then
  for name in "${ENV_NAMES_FROM_FILE[@]}"; do
    ENVS+=(-e "$name")
  done
fi

# Per-profile session location and fresh-start prompt. The resume prompt is
# shared across profiles; only the fresh prompt varies (pi-or runs full
# caveman rather than caveman lite).
case "$PROFILE" in
  claude)                                       SESSION_DIR=.claude/projects ;;
  pi-ollama|pi-azure|pi-or|pi-gemini)           SESSION_DIR=.pi/agent/sessions ;;
  *)                                            SESSION_DIR= ;;
esac
case "$PROFILE" in
  pi-or) FRESH_PROMPT='/skill:caveman\ncarry out doc/PLAN.md' ;;
  *)     FRESH_PROMPT='/skill:caveman lite\ncarry out doc/PLAN.md' ;;
esac
RESUME_PROMPT='Your prior session was interrupted (Mithril spot preemption or a manual exit) and is now being resumed. /workspace and your prior session are bind-mounted from host-persistent storage, so they survived intact. Read /workspace/STATUS.md if present, check `git log` and the working-tree state, then continue carrying out doc/PLAN.md from where you left off. Once you have re-established context, run `rm -f /workspace/.shutdown-acked` so any future preemption is handled cleanly.'

RESUMING=0
[ -n "$SESSION_DIR" ] \
  && [ -n "$(find "$STATE_DIR/home/$SESSION_DIR" -name '*.jsonl' -print -quit 2>/dev/null)" ] \
  && RESUMING=1

if [ "$RESUMING" = 1 ]; then
  echo "run.sh: resuming $PROFILE in $STATE_DIR (make reseed to start fresh)" >&2
  CLAUDE_RESUME=(--continue)
  PI_RESUME=(-c)
  EFFECTIVE_PROMPT="$RESUME_PROMPT"
else
  echo "run.sh: starting fresh $PROFILE in $STATE_DIR" >&2
  CLAUDE_RESUME=()
  PI_RESUME=()
  EFFECTIVE_PROMPT="$FRESH_PROMPT"
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
    # Forward explicitly: the .env passthrough above only catches vars
    # listed in .env, but users may export these in their shell instead.
    ENVS+=(-e AZURE_BASE_URL)
    if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
      echo "pi-azure: set only one of ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      ENVS+=(-e ANTHROPIC_API_KEY)
      PI_MODEL="${PI_MODEL:-claude-opus-4-7}"
      ENVS+=(-e "PI_MODEL=$PI_MODEL")
      ARGS=("${PI_RESUME[@]}" --provider anthropic --model "$PI_MODEL" --thinking xhigh "$EFFECTIVE_PROMPT")
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
      ENVS+=(-e OPENAI_API_KEY)
      PI_MODEL="${PI_MODEL:-gpt-5.5}"
      ENVS+=(-e "PI_MODEL=$PI_MODEL")
      # DeepSeek-V4 on Azure (OpenAI-compatible) only accepts reasoning_effort
      # "high" or "max"; pi's "xhigh" alias would be rejected. Other Azure
      # OpenAI deployments keep xhigh for parity with prior behavior.
      case "$PI_MODEL" in
        DeepSeek-*|deepseek-*) THINKING=high ;;
        *)                     THINKING=xhigh ;;
      esac
      ARGS=("${PI_RESUME[@]}" --provider openai --model "$PI_MODEL" --thinking "$THINKING" "$EFFECTIVE_PROMPT")
    else
      echo "pi-azure: set ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    fi
    ;;
  pi-or)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY must be set for pi-or}"
    ARGS=("${PI_RESUME[@]}" --provider openrouter --api-key "$OPENROUTER_API_KEY" --model moonshotai/kimi-k2.6 --thinking high "$EFFECTIVE_PROMPT")
    ;;
  pi-gemini)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    : "${GEMINI_API_KEY:?GEMINI_API_KEY must be set for pi-gemini}"
    ENVS+=(-e GEMINI_API_KEY)
    PI_MODEL="${PI_MODEL:-gemini-3.1-pro-preview}"
    ENVS+=(-e "PI_MODEL=$PI_MODEL")
    ARGS=("${PI_RESUME[@]}" --provider gemini --model "$PI_MODEL" --thinking high "$EFFECTIVE_PROMPT")
    ;;
  bash)
    ENTRYPOINT=bash
    ARGS=()
    ;;
  *)
    echo "usage: $0 {claude|pi-ollama|pi-azure|pi-gemini|pi-or|bash} [gpu-id|all]" >&2
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
  "$IMAGE" \
  "$ENTRYPOINT" "${ARGS[@]}"
