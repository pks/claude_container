#!/bin/bash
# Install the Mithril host-side resume units. Safe to run on a fresh node OR
# on a live node with an agent already running — the units are registered
# but not started, so the next preemption-recovery boot is the first time
# systemd takes over. To kick it off immediately after install, pass --start.
#
# Assumes:
#   - persistent volume labeled `exp` (xfs) will be (or already is) attached
#   - the repo (this claude_container) is cloned at /home/ubuntu/exp/diffusemt/
#   - the host `ubuntu` user exists with the right UID/GID
#   - tmux, docker, make, and an NVIDIA runtime are installed
#
# If the host currently mounts /home/ubuntu/exp via /etc/fstab, remove that
# entry before the next reboot — fstab and the systemd .mount unit will
# otherwise race on the same path.
#
# Usage:  sudo bash install.sh [--start]
set -euo pipefail

START=0
for arg in "$@"; do
  case "$arg" in
    --start) START=1 ;;
    *) echo "usage: $0 [--start]" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0644 "$HERE/home-ubuntu-exp.mount"     /etc/systemd/system/home-ubuntu-exp.mount
install -m 0644 "$HERE/diffusemt-resume.service"  /etc/systemd/system/diffusemt-resume.service

# Keep ubuntu's user-systemd instance alive across login-free boots; without
# this, the detached tmux server gets reaped seconds after ExecStart returns.
loginctl enable-linger ubuntu

systemctl daemon-reload
systemctl enable home-ubuntu-exp.mount
systemctl enable diffusemt-resume.service

if [ "$START" = 1 ]; then
  systemctl start home-ubuntu-exp.mount
  systemctl start diffusemt-resume.service
fi

cat <<EOF
Installed.

  Units are enabled but $( [ "$START" = 1 ] && echo "started now." || echo "not started." )
  $( [ "$START" = 1 ] || echo "They will activate on the next boot (or run install with --start)." )

Next:
  - On first boot the mount needs the label-tagged disk attached
    (mkfs.xfs -L exp /dev/sdX, chown ubuntu:ubuntu /home/ubuntu/exp).
  - Optional override:  /home/ubuntu/exp/.diffusemt-resume.env
      PROFILE=claude          # or pi-azure, pi-gemini, ...
      GPU=all                 # or 0, 1
      # THINKING=max
  - To watch the agent:  ssh ubuntu@<node>  then  tmux attach -t diffusemt
  - Start manually:      systemctl start diffusemt-resume.service
  - Stop:                systemctl stop  diffusemt-resume.service
EOF
