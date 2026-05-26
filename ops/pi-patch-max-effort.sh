#!/bin/bash
# Patch installed @earendil-works/pi-coding-agent to accept --thinking max.
#
# Why: Opus 4.7 accepts effort "max" via Anthropic's API (verified in Claude
# Code with `/effort max`), but pi has three independent gates that cap
# user-facing thinking at "xhigh". Pi-ai's source comment "effort max is only
# valid on Opus 4.6, Opus 4.7 supports xhigh" is outdated.
#
# This script makes three surgical edits:
#   1) Add "max" to VALID_THINKING_LEVELS in dist/cli/args.js (so the input
#      passes CLI validation).
#   2) Add { "max": "max" } to every Claude model's thinkingLevelMap in
#      pi-ai/dist/models.generated.js, so the adaptive-thinking branch passes
#      effort: "max" straight through to Anthropic's output_config.
#   3) Add "max" to EXTENDED_THINKING_LEVELS in pi-ai/dist/models.js (which
#      drives clampThinkingLevel) and extend the `level === "xhigh"` special
#      case to also accept "max" — otherwise the clamp silently rewrites
#      "max" to "off", and the TUI shows "thinking off" while pretending the
#      input was accepted.
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
MODELS_LIB_JS="$PI_ROOT/node_modules/@earendil-works/pi-ai/dist/models.js"

for f in "$ARGS_JS" "$MODELS_JS" "$MODELS_LIB_JS"; do
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

# 3) EXTENDED_THINKING_LEVELS and the matching filter check in pi-ai/dist/models.js.
# This list drives clampThinkingLevel(); without "max" here the clamp returns "off"
# silently, even though args.js validation accepts the input.
if grep -q '"xhigh", "max"\]' "$MODELS_LIB_JS"; then
  echo "pi-patch-max-effort: models.js already patched"
else
  sed -i \
    -e 's|EXTENDED_THINKING_LEVELS = \["off", "minimal", "low", "medium", "high", "xhigh"\]|EXTENDED_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]|' \
    -e 's|if (level === "xhigh")|if (level === "xhigh" \|\| level === "max")|' \
    "$MODELS_LIB_JS"
  grep -q '"xhigh", "max"\]' "$MODELS_LIB_JS" \
    || { echo "pi-patch-max-effort: models.js EXTENDED_THINKING_LEVELS sed didn't take" >&2; exit 1; }
  grep -q 'level === "xhigh" || level === "max"' "$MODELS_LIB_JS" \
    || { echo "pi-patch-max-effort: models.js filter sed didn't take" >&2; exit 1; }
  echo "pi-patch-max-effort: models.js patched"
fi
