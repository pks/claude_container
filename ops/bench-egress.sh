#!/bin/bash
# Bench egress lock. Runs the agent on an --internal docker network (no route to
# the internet) whose ONLY reachable peer is an allowlist proxy that forwards to
# the inference endpoint host(s) and nothing else. Fail-closed: if the agent's
# HTTP client ignores the proxy env, it reaches nothing rather than leaking.
#
# Flow:  agent (internal net) --> proxy (internal + external nets) --> inference host
#
# Usage:  ./ops/bench-egress.sh [run.sh args...]
#   INFERENCE_ALLOWLIST  comma-separated allowed hostnames (else derived from AZURE_BASE_URL)
#   IMAGE                bench image (must have tinyproxy baked) [mtbench-container]
set -euo pipefail

IMAGE="${IMAGE:-mtbench-container}"
NET="${DOCKER_NETWORK:-mtbench-net}"
NET_EXT="${NET}-ext"
PROXY_NAME="${PROXY_NAME:-mtbench-proxy}"
PROXY_PORT=8888

# Pull the .env so AZURE_BASE_URL is visible for allowlist derivation (run.sh
# parses it again for the container; here we only need the host).
if [ -z "${INFERENCE_ALLOWLIST:-}" ] && [ -f .env ]; then
  base="$(grep -E '^[[:space:]]*(export[[:space:]]+)?AZURE_BASE_URL=' .env | tail -1 | sed -E 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//')"
  [ -n "$base" ] && INFERENCE_ALLOWLIST="$(printf '%s' "$base" | sed -E 's#^https?://##; s#/.*$##')"
fi
: "${INFERENCE_ALLOWLIST:?set INFERENCE_ALLOWLIST or put AZURE_BASE_URL in .env}"
echo "bench-egress: allowlist = $INFERENCE_ALLOWLIST" >&2

# internal net: no gateway to the outside → agent can't leak.
docker network inspect "$NET"     >/dev/null 2>&1 || docker network create --internal "$NET"
# egress-capable net: the proxy's outbound leg only.
docker network inspect "$NET_EXT" >/dev/null 2>&1 || docker network create "$NET_EXT"

# (re)start the proxy: on the internal net (agent talks to it) + the external net
# (it can reach the inference host). Nothing else bridges the two.
docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
docker run -d --name "$PROXY_NAME" --network "$NET" \
  -e INFERENCE_ALLOWLIST="$INFERENCE_ALLOWLIST" \
  --entrypoint /usr/local/bin/proxy-entrypoint.sh "$IMAGE" >/dev/null
docker network connect "$NET_EXT" "$PROXY_NAME"
echo "bench-egress: proxy '$PROXY_NAME' up on network '$NET'" >&2

# Hand off to run.sh with the agent pinned to the internal net + proxy env.
export IMAGE DOCKER_NETWORK="$NET"
export HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}"
export HTTP_PROXY="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1"
exec ./run.sh "$@"
