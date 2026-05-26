#!/bin/bash
# Patch installed @earendil-works/pi-coding-agent to accept --thinking max.
#
# Why: Opus 4.7 accepts effort "max" via Anthropic's API (verified in Claude
# Code with `/effort max`), but pi's input validation (`VALID_THINKING_LEVELS`)
# and the built-in Anthropic model definitions cap user-facing thinking at
# "xhigh". Pi-ai's source comment "effort max is only valid on Opus 4.6, while
# Opus 4.7 supports xhigh" is outdated — Opus 4.7 supports both.
#
# This script makes two surgical edits:
#   1) Add "max" to VALID_THINKING_LEVELS in dist/cli/args.js
#   2) Add { "max": "max" } to every Claude model's thinkingLevelMap in
#      pi-ai/dist/models.generated.js, so the adaptive-thinking branch passes
#      `effort: "max"` straight through to Anthropic's output_config.
#
# Idempotent: re-running is safe (sed match strings won't re-match after the
# patch). Logs each modification so a failed match is obvious.
#
# Re-verify on pi-coding-agent upgrades — the file paths and exact strings
# in `dist/cli/args.js` and `models.generated.js` are likely stable but not
# guaranteed.
set -euo pipefail

PI_ROOT="${PI_ROOT:-${HOME}/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent}"
ARGS_JS="$PI_ROOT/dist/cli/args.js"
MODELS_JS="$PI_ROOT/node_modules/@earendil-works/pi-ai/dist/models.generated.js"

for f in "$ARGS_JS" "$MODELS_JS"; do
  [ -f "$f" ] || { echo "pi-patch-max-effort: missing $f" >&2; exit 1; }
done

# 1) VALID_THINKING_LEVELS in args.js
if grep -q '"xhigh", "max"' "$ARGS_JS"; then
  echo "pi-patch-max-effort: args.js already patched"
else
  sed -i 's|\["off", "minimal", "low", "medium", "high", "xhigh"\]|["off", "minimal", "low", "medium", "high", "xhigh", "max"]|' "$ARGS_JS"
  grep -q '"xhigh", "max"' "$ARGS_JS" \
    || { echo "pi-patch-max-effort: args.js sed didn't take" >&2; exit 1; }
  echo "pi-patch-max-effort: args.js patched"
fi

# 2) thinkingLevelMap entries in models.generated.js
BEFORE=$(grep -c '"max": "max"' "$MODELS_JS" || true)
sed -i 's|thinkingLevelMap: { "xhigh": "xhigh" }|thinkingLevelMap: { "xhigh": "xhigh", "max": "max" }|g' "$MODELS_JS"
AFTER=$(grep -c '"max": "max"' "$MODELS_JS" || true)
echo "pi-patch-max-effort: models.generated.js — $BEFORE → $AFTER thinkingLevelMaps with max"
