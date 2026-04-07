#!/bin/bash
docker run \
  -i \
  --rm \
  --gpus all \
  --network host \
  -v "$PWD":/workspace \
  -w /workspace \
  --entrypoint claude \
  -e ANTHROPIC_API_KEY \
  -e CLAUDE_CODE_ACCEPT_TOS=yes \
  -u $(id -u):$(id -g) \
  claude-code -p - --dangerously-skip-permissions < PLAN.md
