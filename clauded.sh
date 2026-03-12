docker run \
  -it \
  --rm \
  --gpus all \
  --network host \
  -v "$PWD":/workspace \
  -w /workspace \
  --entrypoint claude \
  -u $(id -u):$(id -g) \
  claude-code --dangerously-skip-permissions
