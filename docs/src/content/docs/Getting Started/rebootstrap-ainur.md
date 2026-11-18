---
title: 🔁 Re-bootstrapping Ainur
slug: getting-started/rebootstrap-ainur
description: Bringing every Pi back up on the latest build, including the one that boots from an SD card.
sidebar:
  order: 5
draft: false
---

> tl;dr - start the bootstrap VM, run `bootstrap/netboot/rebootstrap.sh`, wait for the Pis to come back.

Netbooted Pis are easy: they boot whatever the netboot server is serving *right now*, so a reboot is a rebuild. The Pi with an SD card is the awkward one.

## Why the SD card Pi gets left behind

When a netbooted Pi finds an SD card, `sd-flash.sh` (in the netboot [user-data overlay](https://github.com/andrewiankidd/project-iluvatar/blob/main/bootstrap/netboot/assets/ubuntuserver/boot/overlays/netboot/user-data)) writes the builder's `sd.img` onto it, stamps it with the image's hash, and reboots. From then on the firmware finds a bootable card first and never netboots again.

That's the point: it's the node that can come up on its own, with nothing else on the network. But it also means it keeps the build it was flashed with, forever, and the rest of the cluster bootstraps around an old revision.

The fix is to make the card unbootable. Zero its partition table and the start of its boot partition, and the firmware moves on to netboot, `sd-flash.sh` sees a card that doesn't match the current image, flashes it, and the Pi reboots onto the new build.

## Doing it

1. **Start the bootstrap VM.** It builds a fresh image from your checkout and serves it, so there's something to netboot into while the cluster is down.
    ```bash
    ./bootstrap/netboot/vm/start.sh
    ```
2. **Point DHCP option 66 at the VM** (`BOOTSTRAP_IP_ADDRESS`). Once ainur is up it serves netboot itself, but not while it's down, and wiping the SD card Pi takes it down. Point it back at ainur's VIP afterwards.
3. **Re-bootstrap.** Every Pi in `PI_HOSTS`, or just the ones named:
    ```bash
    ./bootstrap/netboot/rebootstrap.sh
    ./bootstrap/netboot/rebootstrap.sh 192.168.1.50
    ```

For each Pi it SSHes in, and if `/` is on the SD card, zeroes the card's first 8 MiB. Then it reboots.

:::note
`wipefs` is not enough. It only clears the partition table's two-byte signature, which the Pi firmware ignores: the Pi boots the kernel from the card anyway, and Linux, which does check the signature, can't find its root partition and stops in the initramfs.
:::

The SD card Pi reboots twice: once into netboot to be flashed, then onto the card. That's about 10 minutes, and it becomes the k3s server. The netbooted Pis wait for it: they learn the leader from ainur (`bootstrap.<domain>/k3s/k3s-leader`) and won't elect themselves, which would make each its own cluster.

The Pis are `192.168.1.50`-`52` with the `ubuntu` user from user-data unless `.env` says otherwise (`PI_HOSTS`, `PI_USER`, `PI_PASSWORD`; see `.env.example`). `ssh` and `sshpass` run in a throwaway container, so Docker is all it needs.

:::caution
This replaces the cluster rather than updating it. The SD card Pi's k3s state lives on the card, so it comes back as a brand new cluster, and everything stored in it (Secrets, Omni's state, Argo CD's) is rebuilt from Git and `.env`. Longhorn's NVMe disks are left alone.
:::

## By hand

If the script can't help (no Docker, no VM), it's the same three commands on the SD card Pi:

```bash
findmnt -no SOURCE /            # /dev/mmcblk0p2 means it booted from the card
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=8 conv=fsync   # no partition table, no boot partition
sudo reboot -f
```

Something still has to be serving netboot when it comes back, so start the VM first either way.
