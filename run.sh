#!/bin/bash
set -eu

PROFILE="${1:-claude}"
GPU="${2:-all}"

case "$GPU" in
  all) GPU_FLAG=(--gpus all) ;;
  *)   GPU_FLAG=(--gpus "device=$GPU") ;;
esac

CONTAINER_NAME="claude-agent-${PROFILE}-${GPU//,/_}"
RESUME_TAG="claude-container:resume"

# If a resume snapshot exists, prefer it over the freshly-built image. Cleared
# manually with `docker rmi claude-container:resume` to start from scratch.
IMAGE=claude-container
RESUMING=0
if docker image inspect "$RESUME_TAG" >/dev/null 2>&1; then
  IMAGE="$RESUME_TAG"
  RESUMING=1
  echo "run.sh: resuming from $RESUME_TAG (rmi to start fresh)" >&2
fi

# Mount Claude Code credentials from host if available
MOUNTS=()
[ -f ~/.claude/.credentials.json ] \
  && MOUNTS+=(-v ~/.claude/.credentials.json:/home/ubuntu/.claude/.credentials.json)
[ -f ~/.claude.json ] \
  && MOUNTS+=(-v ~/.claude.json:/home/ubuntu/.claude.json)

# Mithril spot-interruption: signal file (read-only) + docker socket so the
# in-container watcher can `docker commit` the running container into
# claude-container:resume when STATUS_PREEMPTING / STATUS_RELOCATING is signaled.
[ -d /opt/mithril ] \
  && MOUNTS+=(-v /opt/mithril:/opt/mithril:ro)
[ -S /var/run/docker.sock ] \
  && MOUNTS+=(-v /var/run/docker.sock:/var/run/docker.sock)

ENVS=(
  -e CLAUDE_CODE_THEME=dark
  -e CLAUDE_CODE_ACCEPT_TOS=yes
  -e CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=yes
  -e CLAUDE_CODE_SKIP_TRUST_SCREEN=1
  -e "CONTAINER_NAME=$CONTAINER_NAME"
  -e "RESUME_TAG=$RESUME_TAG"
)

PROMPT='/skill:caveman lite\ncarry out doc/PLAN.md'
RESUME_PROMPT='You were just preempted by a Mithril spot interruption and resumed on a new instance. The container was snapshotted via docker commit, so /workspace and your prior session are intact. Read /workspace/STATUS.md if present, check `git log` and the working-tree state, then continue carrying out doc/PLAN.md from where you left off. Once you have re-established context, run `rm -f /workspace/.shutdown-acked` so the next preemption is handled cleanly.'

# Resume flags per agent: `claude --continue` and `pi -c` both resume the
# most recent session in the current cwd. Sessions live in
# ~/.claude/projects/ and ~/.pi/agent/sessions/ respectively, both inside
# the snapshotted writable layer.
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
  --name "$CONTAINER_NAME" \
  "${GPU_FLAG[@]}" \
  --network host \
  -u "$(id -u):$(id -g)" \
  -w /workspace \
  --entrypoint /usr/local/bin/entrypoint.sh \
  "${MOUNTS[@]}" \
  "${ENVS[@]}" \
  "$IMAGE" \
  "$ENTRYPOINT" "${ARGS[@]}"
