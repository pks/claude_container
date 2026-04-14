#!/bin/bash

# Mount Claude Code credentials from host if available
MOUNTS=()
[ -f ~/.claude/.credentials.json ] \
  && MOUNTS+=(-v ~/.claude/.credentials.json:/home/$(whoami)/.claude/.credentials.json)
[ -f ~/.claude.json ] \
  && MOUNTS+=(-v ~/.claude.json:/home/$(whoami)/.claude.json)

docker run \
  -it \
  --gpus all \
  --network host \
  -u "$(id -u):$(id -g)" \
  -w /workspace \
  --entrypoint claude \
  "${MOUNTS[@]}" \
  -e CLAUDE_CODE_THEME=dark \
  -e CLAUDE_CODE_ACCEPT_TOS=yes \
  -e CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=yes \
  -e CLAUDE_CODE_SKIP_TRUST_SCREEN=1 \
  claude-container \
  --dangerously-skip-permissions --effort low "/caveman light\ncarry out doc/PLAN.md"
