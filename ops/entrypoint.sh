#!/bin/bash
set -eu

# Background the Mithril spot-interruption watcher when the signal mount is
# present. Without it the watcher has nothing to do.
if [ -d /opt/mithril ]; then
  mkdir -p /workspace/log
  /usr/local/bin/mithril-watch.sh >>/workspace/log/mithril-watch.log 2>&1 &
  echo "[entrypoint] mithril watcher started (pid $!)"
fi

exec "$@"
