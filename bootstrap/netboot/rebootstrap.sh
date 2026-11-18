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
#   PI_HOSTS           the Pis                   default: 192.168.1.50 192.168.1.51 192.168.1.52
#   PI_USER            their user                default: ubuntu
#   AINUR_PI_PASSWORD  their password            (the same one user-data sets)
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
PI_PASSWORD="${AINUR_PI_PASSWORD:?set AINUR_PI_PASSWORD in .env}"

# Nothing to boot from if the VM is not serving.
if ! curl -sf --connect-timeout 3 --max-time 5 -o /dev/null "http://$BOOTSTRAP_IP_ADDRESS/user-data"; then
  echo "The bootstrap VM is not serving at $BOOTSTRAP_IP_ADDRESS; start it first: $HERE/vm/start.sh" >&2
  exit 1
fi

# DHCP option 66 to the VM: ainur serves netboot itself, but not while it is
# down, and this takes it down. Its unifi CronJob points it back at ainur's
# VIP once ainur serves netboot again. Needs ARDA_UNIFI_API_KEY; without it,
# set option 66 to the VM by hand.
if [ -n "${ARDA_UNIFI_API_KEY:-}" ]; then
  MSYS_NO_PATHCONV=1 docker run --rm -e KEY="$ARDA_UNIFI_API_KEY" -e VM="$BOOTSTRAP_IP_ADDRESS" \
    -e URL="${ARDA_UNIFI_URL:-https://192.168.1.1}" alpine:3.20 sh -c '
    apk add -q --no-cache curl jq >/dev/null
    api() { curl -fsSk -H "X-API-KEY: $KEY" -H "Content-Type: application/json" "$@"; }
    base="$URL/proxy/network/api/s/default/rest/networkconf"
    api "$base" | jq -c --arg p "${VM%.*}." ".data[] | select(.purpose == \"corporate\" and ((.ip_subnet // \"\") | startswith(\$p)))" \
      | while read -r net; do
        echo "option 66 on $(echo "$net" | jq -r .name): $(echo "$net" | jq -r ".dhcpd_tftp_server // \"unset\"") -> $VM"
        api -o /dev/null -X PUT "$base/$(echo "$net" | jq -r ._id)" --data "{\"dhcpd_tftp_server\":\"$VM\"}"
      done'
else
  echo "No ARDA_UNIFI_API_KEY: point DHCP option 66 at $BOOTSTRAP_IP_ADDRESS yourself." >&2
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
      -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      -o LogLevel=ERROR "$PI_USER@$h" "sudo sh -c '\''$REMOTE'\''" \
      || echo "($h unreachable, or dropped the connection to reboot)"
  done'

echo "Done. The Pis netboot from $BOOTSTRAP_IP_ADDRESS; an SD-card Pi reboots twice (flash, then boot)."
