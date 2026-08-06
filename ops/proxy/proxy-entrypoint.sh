#!/bin/bash
# Bench egress proxy entrypoint. Turns $INFERENCE_ALLOWLIST (comma-separated
# hostnames) into an anchored POSIX-ERE allowlist file, then runs tinyproxy in
# the foreground. tinyproxy is configured FilterDefaultDeny → only these exact
# hosts are reachable; everything else is refused.
set -euo pipefail

: "${INFERENCE_ALLOWLIST:?set INFERENCE_ALLOWLIST to comma-separated allowed hostnames}"

ALLOWLIST=/etc/tinyproxy/allowlist
: > "$ALLOWLIST"
IFS=',' read -ra HOSTS <<< "$INFERENCE_ALLOWLIST"
for h in "${HOSTS[@]}"; do
  h="$(echo "$h" | xargs)"        # trim whitespace
  [ -z "$h" ] && continue
  esc="$(printf '%s' "$h" | sed 's/[.]/\\./g')"   # escape dots
  printf '^%s$\n' "$esc" >> "$ALLOWLIST"          # anchor to exact host
done

echo "[proxy] egress allowlist (default-deny for all others):" >&2
sed 's/^/[proxy]   /' "$ALLOWLIST" >&2

exec tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf
