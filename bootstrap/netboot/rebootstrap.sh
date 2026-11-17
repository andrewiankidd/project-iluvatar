#!/bin/bash
# Re-bootstraps ainur from the bootstrap VM's latest build: reboots every Pi
# onto it. A Pi running from its SD card has the card wiped first, so it falls
# back to netboot, where sd-flash.sh writes the new image to the card and
# reboots into it. Without that, it keeps whatever it was flashed with.
#
#   ./vm/start.sh                     build the image and serve it
#   ./rebootstrap.sh                  every Pi in PI_HOSTS
#   ./rebootstrap.sh 192.168.1.50     just that one
#
# Settings, from the environment or .env (see .env.example):
#   PI_HOSTS     the Pis                   default: 192.168.1.50 192.168.1.51 192.168.1.52
#   PI_USER      their user                default: ubuntu
#   PI_PASSWORD  its password (user-data)  default: ubuntu
#
# Needs Docker: ssh and sshpass run in a container.
# Docs: https://andrewiankidd.github.io/project-iluvatar/getting-started/rebootstrap-ainur/
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/.env" ]; then
  set -a; . "$HERE/.env"; set +a
fi
PI_HOSTS="${*:-${PI_HOSTS:-192.168.1.50 192.168.1.51 192.168.1.52}}"
PI_USER="${PI_USER:-ubuntu}"
PI_PASSWORD="${PI_PASSWORD:-ubuntu}"

# Nothing to boot from if the VM is not serving.
if ! curl -sf --connect-timeout 3 --max-time 5 -o /dev/null "http://$BOOTSTRAP_IP_ADDRESS/user-data"; then
  echo "The bootstrap VM is not serving at $BOOTSTRAP_IP_ADDRESS; start it first: $HERE/vm/start.sh" >&2
  exit 1
fi

# On the Pi: if it booted from its SD card, zero the card's partition table
# and the start of its boot partition, so the firmware finds nothing to boot
# and moves on to netboot, then reboot. wipefs is not enough: it clears only
# the MBR signature, which the firmware ignores, and the Pi boots a kernel
# that then can't find its root partition.
remote='
if findmnt -no SOURCE / | grep -q "^/dev/mmcblk0"; then
  echo "booted from its SD card; wiping it so it netboots the new image"
  sync
  dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=8 conv=fsync status=none
fi
echo "rebooting"
systemctl reboot
'

MSYS_NO_PATHCONV=1 docker run --rm -e PI_HOSTS="$PI_HOSTS" -e PI_USER="$PI_USER" \
  -e SSHPASS="$PI_PASSWORD" -e REMOTE="$remote" alpine:3.20 sh -c '
  apk add -q --no-cache openssh-client sshpass
  for h in $PI_HOSTS; do
    echo "== $h"
    sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o LogLevel=ERROR "$PI_USER@$h" "sudo sh -c '\''$REMOTE'\''" \
      || echo "($h unreachable, or dropped the connection to reboot)"
  done'

echo "Done. The Pis netboot from $BOOTSTRAP_IP_ADDRESS; an SD-card Pi reboots twice (flash, then boot)."
