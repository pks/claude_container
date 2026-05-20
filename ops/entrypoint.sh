#!/bin/bash
set -eu

# Background the Mithril spot-interruption watcher when the signal mount is
# present. Without it the watcher has nothing to do.
if [ -d /opt/mithril ]; then
  mkdir -p /workspace/log
  /usr/local/bin/mithril-watch.sh >>/workspace/log/mithril-watch.log 2>&1 &
  echo "[entrypoint] mithril watcher started (pid $!)"
fi

# Switch pi's settings.json based on the active model. GPT-5 series has a
# 272K-input pricing cliff (2x input / 1.5x output above that), so it gets a
# profile that compacts well before that line; everything else uses the
# 1M-context profile that compacts at ~80% utilization.
PI_SETTINGS_TARGET=/home/ubuntu/.pi/agent/settings.json
PI_SETTINGS_SRC_DIR=/etc/pi-settings
if [ -d "$PI_SETTINGS_SRC_DIR" ]; then
  case "${PI_MODEL:-}" in
    gpt-*|GPT-*) profile=gpt ;;
    *)           profile=default ;;
  esac
  src="$PI_SETTINGS_SRC_DIR/settings.${profile}.json"
  if [ -f "$src" ]; then
    install -D -m 0644 "$src" "$PI_SETTINGS_TARGET"
    echo "[entrypoint] pi settings profile: $profile (PI_MODEL=${PI_MODEL:-unset})"
  fi
fi

exec "$@"
