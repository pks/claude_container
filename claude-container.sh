#!/bin/bash
docker run \
  -it \
  --gpus all \
  --network host \
  -u $(id -u):$(id -g) \
  -w /workspace \
  --entrypoint claude \
  -e CLAUDE_CODE_THEME=dark \
  -e CLAUDE_CODE_ACCEPT_TOS=yes \
  -e CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=yes \
  claude-container --dangerously-skip-permissions --effort low "/caveman light\ncarry out doc/PLAN.md"
