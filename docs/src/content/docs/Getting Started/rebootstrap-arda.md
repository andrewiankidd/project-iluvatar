---
title: 🔁 Re-bootstrapping Arda
slug: getting-started/rebootstrap-arda
description: Getting an x86 machine with an old or half-finished Talos install to boot the USB stick and join Omni.
sidebar:
  order: 6
draft: false
---

> tl;dr - read its address off its console, run `bootstrap/arda/rebootstrap.sh <address>`, reboot it.

A ProDesk that has run Talos before boots that install from its NVMe, ahead of the USB stick. If it never got a config, it sits in **maintenance mode**: the console shows `STAGE Maintenance` and `SIDEROLINK n/a`, and waits.

That old install is a dead end:

- **It may not join Omni at all.** Without Omni's join settings it has no idea Omni exists.
- **It may be too old.** Pushed Omni's join settings by hand, an older Talos shows up in Omni, but can't apply the cluster's config: Omni's config for a newer Talos has documents the old one doesn't know (`"DiscoveryServiceConfig" "v1alpha1": not registered` in Omni's log), and Omni won't upgrade it until that config applies.
- **Its boot menu may ignore the keyboard.** Talos's own boot menu waits 2 seconds and, at least through a JetKVM, doesn't take input, so you can't pick the firmware or the stick from it.

The fix is the same idea as [the SD card Pi](/project-iluvatar/getting-started/rebootstrap-ainur/#why-the-sd-card-pi-gets-left-behind): make the disk unbootable, and the firmware moves on to the USB stick.

## Doing it

1. **Plug in the USB stick** with ainur's ISO (`http://bootstrap.example.com/talos-media/metal-amd64.iso`; see [the Quickstart](/project-iluvatar/getting-started/quickstart/#omni-and-arda)).
2. **Read its address off the console**: the `IP` line, top right.
3. **Wipe its Talos install**:
    ```bash
    ./bootstrap/arda/rebootstrap.sh 192.168.1.238
    ```
    It finds the disk Talos is installed on and wipes its boot, `STATE` and `EPHEMERAL` partitions over the maintenance-mode API, which needs no credentials. Other disks (the SATA SSD Longhorn uses, the stick) are left alone.
4. **Reboot it**: Ctrl+Alt+Del on its KVM. Maintenance mode can't be rebooted over the network.

It boots the stick, the console shows the new Talos version with SideroLink connected, and it appears under *Machines* in Omni. The cluster template takes it from there: it installs to the NVMe and reboots into the cluster.

`talosctl` runs in a container, so Docker is all it needs.

:::note
`META`, the 1 MB partition Talos keeps its own settings in, can't be wiped while maintenance mode is using it. It doesn't need to be: without the boot partition the disk isn't bootable, and the install replaces it.
:::

## A machine that's already in a cluster

It isn't in maintenance mode, so the script refuses it. Remove it from the cluster in Omni instead: Omni resets it, wiping its disk, and it comes back in maintenance mode, ready to be allocated again.

## By hand

It's two `talosctl` commands. Find the partitions, then wipe the ones on the disk with the `EFI` partition:

```bash
talosctl -n 192.168.1.238 -e 192.168.1.238 get discoveredvolumes --insecure
talosctl -n 192.168.1.238 -e 192.168.1.238 wipe disk nvme0n1p1 nvme0n1p3 nvme0n1p4 --insecure
```

Use a `talosctl` no newer than the machine's Talos: a newer one won't talk to an older Talos in maintenance mode (`API is not implemented in maintenance mode`).
