#!/bin/bash
set -eu

# Switch pi's settings.json based on the active model. GPT-5 series has a
# 272K-input pricing cliff (2x input / 1.5x output above that), so it gets a
# profile that compacts well before that line; everything else uses the
# 1M-context profile that compacts at ~80% utilization.
#
# The seeded settings.json carries `.extensions` populated by `pi install` at
# image build time. A plain overwrite would wipe that field and silently
# disable every pi extension (azure-anthropic, gemini, …). Merge
# instead: profile keys (retry/compaction) win; everything else is preserved.
PI_SETTINGS_TARGET="${HOME:-/home/ubuntu}/.pi/agent/settings.json"
PI_SETTINGS_SRC_DIR=/etc/pi-settings
# Only run pi-settings profile selection when actually launching pi. Claude
# Code runs don't need it, and the [entrypoint] log line is misleading then.
case "${1:-}" in
  pi|*/pi) RUN_PI_SETTINGS=1 ;;
  *)       RUN_PI_SETTINGS=0 ;;
esac
if [ "$RUN_PI_SETTINGS" = 1 ] && [ -d "$PI_SETTINGS_SRC_DIR" ]; then
  case "${PI_MODEL:-}" in
    gpt-*|GPT-*) profile=gpt ;;
    *)           profile=default ;;
  esac
  src="$PI_SETTINGS_SRC_DIR/settings.${profile}.json"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$PI_SETTINGS_TARGET")"
    if [ -f "$PI_SETTINGS_TARGET" ]; then
      tmp="$(mktemp)"
      if jq -s '.[0] * .[1]' "$PI_SETTINGS_TARGET" "$src" > "$tmp"; then
        install -m 0644 "$tmp" "$PI_SETTINGS_TARGET"
      else
        echo "[entrypoint] pi settings merge failed — falling back to overwrite" >&2
        install -D -m 0644 "$src" "$PI_SETTINGS_TARGET"
      fi
      rm -f "$tmp"
    else
      install -D -m 0644 "$src" "$PI_SETTINGS_TARGET"
    fi
    echo "[entrypoint] pi settings profile: $profile (PI_MODEL=${PI_MODEL:-unset})"
  fi
fi

exec "$@"
