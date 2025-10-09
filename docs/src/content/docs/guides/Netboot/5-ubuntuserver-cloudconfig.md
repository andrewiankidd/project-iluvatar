---
title: 'Ubuntu Server & Cloud Config'
description: It's all Debian at the end of the day
---

This guide covers how I build a reusable, netboot-friendly Ubuntu Server image for the Raspberry Pi bootstrap cluster using cloud-init.

## Explanation

RaspiOS got me through the first experiments, but I always wanted something I could automate with cloud-init and manage with the same tooling I use elsewhere. Ubuntu Server ticks those boxes: official images for the Pi, first-class cloud-init support, and enough packages out of the box to let the bootstrap nodes run k3s, dnsmasq, and the PXE stack without hacks.

### About cloud-init

Ubuntu Server images ship with [cloud-init](https://cloud-init.io/), Canonical’s declarative bootstrap system. It processes `user-data` and `network-data` files on first boot and handles:

- Creating users, SSH keys, packages, and services
- Applying static network config or DHCP settings
- Running arbitrary shell commands during provisioning

Because the Raspberry Pi firmware treats the boot partition like removable storage, we can drop `user-data`/`network-data` files straight into the TFTP share and every Pi that netboots will consume the same declarative configuration.

### Components
- **Ubuntu Server (Raspberry Pi build)**
    - Official 64-bit ARM image with cloud-init baked in.
- **cloud-config (`user-data`)**
    - YAML file that defines users, packages, and bootstrap commands (installing k3s, logging markers, etc.).
- **network-config (`network-data`)**
    - Optional static/DHCP config that cloud-init applies on first boot.
- **Dockerised PXE stack**
    - TFTP + NFS servers that host the boot files and root filesystem for every node.

## Implementation

### Obtaining the Boot + OS files

Ubuntu *does* use a traditional ext4 root filesystem, so the RaspiOS workflow still applies: download the preinstalled image, mount the partitions, sync the contents to our NFS/TFTP exports, then patch `cmdline.txt` and `fstab` to point at the NFS root.

The heavy lifting lives in the repo inside `bootstrap/netboot`. With `COMPOSE_PROFILE=ubuntuserver` set in `.env`, the builder script will:

1. Fetch the latest `ubuntu-24.04.x-preinstalled-server-arm64+raspi.img.xz`.
2. Mount the image via loopback.
3. Copy `boot` into the TFTP volume and `rootfs` into the NFS share.
4. Patch `cmdline.txt` and `fstab` so Pi firmware mounts our NFS export.
5. Overlay any cloud-init assets from `assets/ubuntuserver`.

## Running
:::tip[Requirement]
You need Docker (or Multipass + the provided VM scripts) to run the PXE stack locally while the image is being prepared.
:::

1. Copy `.env.example` to `.env` and set `COMPOSE_PROFILE=ubuntuserver`.
2. Adjust `DOWNLOAD_LINK`, `CLEAN_BOOT_FILES`, or other options if you want a different Ubuntu release.
3. Run the builder:

```bash
cd bootstrap/netboot
docker compose --profile ubuntuserver up --build
```

Behind the scenes this runs `scripts/build-debian.sh` (name pending better branding). When it finishes you’ll have:

```
boot/               # files served over TFTP
os/ubuntu-24.04...  # root filesystem exported via NFS
boot/user-data      # cloud-config injected by the build
boot/network-data   # network config consumed by cloud-init
```

### Modifying the Bootloader & OS to use NFS

The build script patches two files automatically:

- `boot/cmdline.txt` – points `root=/dev/nfs` and `nfsroot=192.168.0.66:/mnt/nfsshare/<image>` so the Pi kernel mounts your NFS export.
- `os/<image>/etc/fstab` – ensures `/` and `/boot/firmware` map to those same NFS paths once systemd takes over.

If you change the NFS server IP or directory structure, rerun the build with the updated `.env`.

### Unattended Installation via cloud-config

Rather than baking configs into the root filesystem, cloud-init lets us drop plain YAML files in the boot partition.

- [`assets/ubuntuserver/boot/user-data`](../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) defines the bootstrap user, installs k3s, and leaves a breadcrumb log.
- [`assets/ubuntuserver/boot/network-data`](../../../../bootstrap/netboot/assets/ubuntuserver/boot/network-data) keeps networking simple (DHCP on `eth0` by default).

Need different roles? Copy those files, tweak hostnames, tokens, or additional packages, and rerun the builder. Every Pi that netboots will pick up the new config on first boot.

## Result
With the files copied over, flipping on a Raspberry Pi is wonderfully boring: it fetches `start4.elf` and friends from TFTP, mounts the Ubuntu rootfs via NFS, cloud-init runs the k3s install script, and within a couple of minutes the node registers itself with the bootstrap cluster.

## Automation

The `docker compose --profile ubuntuserver up` path is self-contained: it downloads the image, extracts it, patches the right files, applies cloud-config assets, and spins up TFTP/NFS containers for local testing. If you prefer running it inside the dedicated Multipass VM, check out [`bootstrap/netboot/vm`](../../../../bootstrap/netboot/vm) for the reproducible setup that powers the same workflow.

## Next Steps

If you came here to learn more about booting a Raspberry Pi over the network, then I hope this helped.

That requirement is now fulfilled, however for my needs there is much more to do 🤠
