#!/bin/bash
set -eu

# Background the Mithril spot-interruption watcher when both the signal mount
# and the docker socket are present. Without those two, the watcher cannot do
# anything useful, so we silently skip.
if [ -d /opt/mithril ] && [ -S /var/run/docker.sock ]; then
  if [ -z "${CONTAINER_NAME:-}" ]; then
    echo "[entrypoint] CONTAINER_NAME not set; mithril watcher disabled" >&2
  else
    mkdir -p /workspace/log
    /usr/local/bin/mithril-watch.sh >>/workspace/log/mithril-watch.log 2>&1 &
    echo "[entrypoint] mithril watcher started (pid $!) for $CONTAINER_NAME"
  fi
fi

exec "$@"
