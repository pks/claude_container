#!/bin/bash
# Install the MT-bench host-side preempt-resume unit. Safe on a live host (the
# unit is registered but not started unless --start; the next preemption boot is
# when systemd takes over). Set host specifics in /etc/mtbench-resume.env first
# (see mtbench-resume.env.example).
#
# Assumes: docker + NVIDIA runtime + tmux installed; the bench repo cloned at
# $REPO; a durable state volume (surviving preemption) mounted at $STATE_DIR.
#
# Usage:  sudo bash install.sh [--start]
set -euo pipefail

START=0
for a in "$@"; do
  case "$a" in
    --start) START=1 ;;
    *) echo "usage: $0 [--start]" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 0644 "$HERE/bench-resume.service" /etc/systemd/system/bench-resume.service
# bench-resume.sh must live OFF the state volume: ExecStart runs before the
# volume is guaranteed attached (soft deps + in-script wait), so a copy under
# the state dir would be unreadable at that point.
install -m 0755 "$HERE/bench-resume.sh"      /usr/local/bin/bench-resume.sh

# Keep the ubuntu user-systemd instance alive across login-free boots, else the
# detached tmux server is reaped seconds after ExecStart returns.
loginctl enable-linger ubuntu || true

systemctl daemon-reload
systemctl enable bench-resume.service
[ "$START" = 1 ] && systemctl start bench-resume.service

echo "installed bench-resume.service (enabled$([ "$START" = 1 ] && echo ", started"))."
echo "set host specifics in /etc/mtbench-resume.env (see mtbench-resume.env.example)."
