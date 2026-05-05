#!/bin/bash
set -eu

PROFILE="${1:-claude}"
GPU="${2:-all}"

case "$GPU" in
  all) GPU_FLAG=(--gpus all) ;;
  *)   GPU_FLAG=(--gpus "device=$GPU") ;;
esac

# /workspace and /home/ubuntu bind-mount from $STATE_DIR so code, ckpts,
# sessions, plugins, npm-global, etc. survive container exits and same-
# node-type Mithril spot relocations (which preserve the root disk).
STATE_DIR="${DIFFUSEMT_STATE:-$PWD/state}"
mkdir -p "$STATE_DIR"/{workspace,home}

seeded=0
seed_from_image() {
  local src="$1" dst="$2"
  [ -n "$(ls -A "$dst" 2>/dev/null)" ] && return 0
  echo "run.sh: seeding $dst <- $src" >&2
  local cid
  cid=$(docker create claude-container)
  docker cp "$cid:$src/." "$dst/"
  docker rm "$cid" >/dev/null
  seeded=1
}
seed_from_image /workspace      "$STATE_DIR/workspace"
seed_from_image /home/ubuntu    "$STATE_DIR/home"

# Refuse to start when state was seeded against a different image — the
# image-side bits in /home/ubuntu/ (settings.json, plugins, npm globals)
# won't reach the bind-mounted home, so behavior diverges silently.
# Override with DIFFUSEMT_FORCE=1.
IMAGE_VERSION=$(docker image inspect claude-container --format '{{index .Config.Labels "diffusemt.version"}}' 2>/dev/null || true)
[ -z "$IMAGE_VERSION" ] && IMAGE_VERSION=unknown
SEED_VERSION_FILE="$STATE_DIR/.image-version"
if [ "$seeded" = 1 ] || [ ! -f "$SEED_VERSION_FILE" ]; then
  echo "$IMAGE_VERSION" > "$SEED_VERSION_FILE"
elif [ "$(cat "$SEED_VERSION_FILE")" != "$IMAGE_VERSION" ] && [ "${DIFFUSEMT_FORCE:-}" != 1 ]; then
  echo "run.sh: state seeded against image $(cat "$SEED_VERSION_FILE"), current is $IMAGE_VERSION" >&2
  echo "run.sh: rm -rf $STATE_DIR/home (and/or $STATE_DIR/workspace) to re-seed, or DIFFUSEMT_FORCE=1 to override" >&2
  exit 1
fi

HAS_CLAUDE_SESSION=0
HAS_PI_SESSION=0
[ -n "$(find "$STATE_DIR/home/.claude/projects" -name '*.jsonl' -print -quit 2>/dev/null)" ] \
  && HAS_CLAUDE_SESSION=1
[ -n "$(find "$STATE_DIR/home/.pi/agent/sessions" -name '*.jsonl' -print -quit 2>/dev/null)" ] \
  && HAS_PI_SESSION=1

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

PROMPT='/skill:caveman lite\ncarry out doc/PLAN.md'
RESUME_PROMPT='You were just preempted by a Mithril spot interruption and resumed on a new instance. /workspace and your prior session are bind-mounted from host-persistent storage, so they survived intact. Read /workspace/STATUS.md if present, check `git log` and the working-tree state, then continue carrying out doc/PLAN.md from where you left off. Once you have re-established context, run `rm -f /workspace/.shutdown-acked` so the next preemption is handled cleanly.'

case "$PROFILE" in
  claude)         RESUMING="$HAS_CLAUDE_SESSION" ;;
  pi-ollama|pi-azure|pi-or) RESUMING="$HAS_PI_SESSION" ;;
  *)              RESUMING=0 ;;
esac

if [ "$RESUMING" = 1 ]; then
  echo "run.sh: resuming $PROFILE in $STATE_DIR (rm -rf $STATE_DIR to start fresh)" >&2
  CLAUDE_RESUME=(--continue)
  PI_RESUME=(-c)
  EFFECTIVE_PROMPT="$RESUME_PROMPT"
else
  echo "run.sh: starting fresh $PROFILE in $STATE_DIR" >&2
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
    if [ "$RESUMING" = 1 ]; then
      OR_PROMPT="$RESUME_PROMPT"
    else
      OR_PROMPT='/skill:caveman\ncarry out doc/PLAN.md'
    fi
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
