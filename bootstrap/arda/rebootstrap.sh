#!/bin/bash
# For an x86 machine sitting in Talos maintenance mode on an old install that
# boots ahead of the USB stick: wipes that install's boot partition, so the
# disk can't boot and the firmware falls through to the stick.
#
#   ./rebootstrap.sh 192.168.1.238        the address on its console
#
# This only gets it to the stick. The old install's META partition is still
# there, so then: reboot it (Ctrl+Alt+Del on its KVM; maintenance mode has no
# reboot over the network), pick "Reset system disk" at the stick's boot menu,
# and if Omni has seen the machine before, delete it in Omni so it can
# register again.
#
# A machine Omni installed doesn't need this: remove it from the cluster in
# Omni, which resets it properly. It isn't in maintenance mode, and this
# refuses it.
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
  # The partition labelled EFI that Talos installed.
  efi=$(awk '/^---/ {if (l == "EFI") print id; id = l = ""}
    /^    id:/ {id = $2} /^    partition_label:/ {l = $2}
    END {if (l == "EFI") print id}' <<<"$yaml" | head -n1)
  if [ -z "$efi" ]; then
    echo "no Talos boot partition found; it should already boot from the stick"
    continue
  fi
  echo "wiping $efi, the old install's boot partition"
  talosctl wipe disk "$efi"
done

echo "Done. Reboot each one (Ctrl+Alt+Del on its KVM), then pick \"Reset system disk\" at the stick's boot menu."
