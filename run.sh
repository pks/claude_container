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

case "$PROFILE" in
  claude)
    ENTRYPOINT=claude
    if [ "$RESUMING" = 1 ]; then
      ARGS=(--continue --dangerously-skip-permissions --model claude-opus-4-6 --effort max "$RESUME_PROMPT")
    else
      ARGS=(--dangerously-skip-permissions --model claude-opus-4-6 --effort max "$PROMPT")
    fi
    ;;
  pi-ollama)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    ARGS=(--provider ollama --model qwen3.6:35b --thinking max "$PROMPT")
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
      ARGS=(--provider anthropic --model "${PI_MODEL:-claude-opus-4-7}" --thinking xhigh "$PROMPT")
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
      ENVS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
      ARGS=(--provider openai --model "${PI_MODEL:-gpt-5}" --thinking high "$PROMPT")
    else
      echo "pi-azure: set ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    fi
    ;;
  pi-or)
    ENTRYPOINT=/home/ubuntu/.npm-global/bin/pi
    : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY must be set for pi-or}"
    ARGS=(--provider openrouter --api-key "$OPENROUTER_API_KEY" --model moonshotai/kimi-k2.6 --thinking high '/skill:caveman\ncarry out doc/PLAN.md')
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
