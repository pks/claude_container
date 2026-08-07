#!/bin/bash
# Bench egress proxy entrypoint. Turns $INFERENCE_ALLOWLIST (comma-separated
# hostnames) into an anchored POSIX-ERE allowlist file, then runs tinyproxy in
# the foreground. tinyproxy is configured FilterDefaultDeny → only these exact
# hosts are reachable; everything else is refused.
set -euo pipefail

: "${INFERENCE_ALLOWLIST:?set INFERENCE_ALLOWLIST to comma-separated allowed hostnames}"

# /tmp (world-writable) so the proxy can run as the unprivileged image user —
# /etc/tinyproxy is root-owned and the image drops sudo/root. tinyproxy.conf's
# Filter points here.
ALLOWLIST=/tmp/mtbench-allowlist
: > "$ALLOWLIST"
IFS=',' read -ra HOSTS <<< "$INFERENCE_ALLOWLIST"
for h in "${HOSTS[@]}"; do
  h="$(echo "$h" | xargs)"        # trim whitespace
  [ -z "$h" ] && continue
  esc="$(printf '%s' "$h" | sed 's/[.]/\\./g')"   # escape dots
  # anchor to the exact host, allowing an optional :port (tinyproxy may present
  # the CONNECT target as host:443, which a bare $-anchor would reject → the
  # inference endpoint would be blocked; fail-closed but the run dies). audit MED.
  printf '^%s(:[0-9]+)?$\n' "$esc" >> "$ALLOWLIST"
done

echo "[proxy] egress allowlist (default-deny for all others):" >&2
sed 's/^/[proxy]   /' "$ALLOWLIST" >&2

exec tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf
