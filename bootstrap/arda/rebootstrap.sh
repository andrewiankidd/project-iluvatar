#!/bin/bash
# Makes an x86 machine that's sitting in Talos maintenance mode (an old
# install, or one that never got a config) boot the USB stick again: wipes the
# boot, STATE and EPHEMERAL partitions of its Talos install, so the firmware
# finds nothing to boot on that disk and moves on to USB. Other disks (the
# SATA SSD Longhorn uses, the stick itself) are left alone.
#
#   ./rebootstrap.sh 192.168.1.238        the address on its console
#
# Then reboot it (Ctrl+Alt+Del on its KVM): maintenance mode has no reboot
# over the network.
#
# A machine already in a cluster isn't in maintenance mode, and this refuses
# it; remove it from the cluster in Omni instead, which resets it.
#
# Needs Docker: talosctl runs in a container.
# Docs: https://andrewiankidd.github.io/project-iluvatar/getting-started/rebootstrap-arda/
set -euo pipefail

[ $# -gt 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 1; }

# Newer talosctl won't talk to an older Talos in maintenance mode; this one
# talks to everything from it up.
TALOSCTL_VERSION="${TALOSCTL_VERSION:-v1.11.6}"
talosctl() {
  MSYS_NO_PATHCONV=1 docker run --rm "ghcr.io/siderolabs/talosctl:$TALOSCTL_VERSION" \
    --nodes "$node" --endpoints "$node" "$@" --insecure
}

for node in "$@"; do
  echo "== $node"
  if ! yaml=$(talosctl get discoveredvolumes -o yaml 2>&1); then
    echo "not in maintenance mode, or unreachable: $yaml" >&2
    continue
  fi
  # "<disk> <partition label> <partition>" per volume.
  vols=$(awk '/^---/ {if (id) print p, l, id; id = p = l = ""}
    /^    id:/ {id = $2} /^    parent:/ {p = $2} /^    partition_label:/ {l = $2}
    END {if (id) print p, l, id}' <<<"$yaml")
  # The disk with the EFI partition Talos installed, and its partitions.
  disk=$(awk '$2 == "EFI" {print $1; exit}' <<<"$vols")
  if [ -z "$disk" ]; then
    echo "no Talos install found; it should already boot from USB"
    continue
  fi
  parts=$(awk -v d="$disk" '$1 == d && ($2 == "EFI" || $2 == "STATE" || $2 == "EPHEMERAL") {print $3}' <<<"$vols")
  echo "wiping $(echo $parts) on $disk"
  # META stays: it's in use in maintenance mode, and harmless.
  talosctl wipe disk $parts
done

echo "Done. Reboot each one (Ctrl+Alt+Del on its KVM); it boots the USB stick."
