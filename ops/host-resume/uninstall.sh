#!/bin/bash
# Remove the MT-bench host-side preempt-resume unit installed by install.sh.
# Stops + disables the service and deletes the unit + script. Leaves the host
# config (/etc/mtbench-resume.env) and linger alone unless --purge is given.
#
# Usage:  sudo bash uninstall.sh [--purge]
#   --purge  also remove /etc/mtbench-resume.env and disable linger for ubuntu
set -euo pipefail

PURGE=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    *) echo "usage: $0 [--purge]" >&2; exit 1 ;;
  esac
done

# disable --now = stop + un-enable in one step; ignore if already gone.
systemctl disable --now bench-resume.service 2>/dev/null || true
rm -f /etc/systemd/system/bench-resume.service
rm -f /usr/local/bin/bench-resume.sh
systemctl daemon-reload

if [ "$PURGE" = 1 ]; then
  rm -f /etc/mtbench-resume.env
  # only affects the ubuntu user; skip if other user services rely on linger.
  loginctl disable-linger ubuntu || true
fi

echo "removed bench-resume.service$([ "$PURGE" = 1 ] && echo " + config/linger (purged)")."
