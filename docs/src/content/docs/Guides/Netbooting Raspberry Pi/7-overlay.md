---
title: 'Supporting Multiple Pis'
slug: guides/netbooting-raspberry-pi/overlay
description: Share one immutable NFS root across many Pis; keep per‑node writes in RAM.
sidebar:
  order: 7
draft: false
---

## Explanation

Currently I am able to boot a completely diskless Raspberry Pi into a fully configured Ubuntu Server OS over the network, by utilizing an NFSv3 server as the root filesystem.

However, if I were to try and boot further machines off of the same root filesystem, I would no doubt be flooded with errors as each system attempts to modify the shared OS root and create handles on the files

Most guides or documentation online suggest working around this by provisioning a copy of the filesystem per machine, for example;
```
 - /mnt/nfsshare/ubuntu-server-24-04-node01
 - /mnt/nfsshare/ubuntu-server-24-04-node02
```

But I see this as wasteful and likely better suited to trying an alternative OS. In my humble opinion the OS root should be the same across all machines, immutable and immune to per machine drift.

So instead I offer this alternative:
  1. Have the Pi mount the nfs share as read only root
  2. Use OverlayFS to make any runtime changes in memory/tmpfs

## Implementation

For multi‑Pi netboot the goal is simple: a single, read‑only OS image that every node boots, with any runtime changes kept off the shared root.

Overlayroot achieves this by placing a writable tmpfs layer over an immutable lower filesystem (our NFS export).

Each Pi sees a normal, writable root, but all writes land in RAM and vanish on reboot.

This gives a single shared golden image for all nodes (easy patching/rollbacks).
<!-- - No SD cards; fast, consistent boots. -->
<!-- - Clean, ephemeral runtime per node. Persist only what you choose (e.g., `/home`). -->

### Kernel parameters

Point the kernel at the shared NFS root and enable the overlay layer:

``` ini
# cmdline.txt
root=/dev/nfs rw \
nfsroot=192.168.1.66:/mnt/nfsshare/<image>,v3,tcp,ro \
modules-load=overlay overlayroot=tmpfs \
ip=dhcp
```

Notes:
- `rw` applies to the final overlay root; the lower NFS layer is made `ro` in `nfsroot=...`.
- Short NFS options (`v3,tcp`) are required by early boot.

### Enable OverlayFS

Overlayroot reads a simple config file during early boot:

``` ini
# /etc/overlayroot.conf
overlayroot="tmpfs"
overlayroot_overlayfs_opts="redirect_dir=off,index=off,metacopy=off"
```

The extra `overlayfs_opts` make OverlayFS happy when the lower filesystem is NFS (they disable features the kernel cannot guarantee on NFS lowers).

### Keep logs light

To avoid noisy disk writes and journald watchdog timeouts on a volatile root, keep the system journal entirely in RAM with compression and strict size limits so it can’t exhaust memory on a diskless system.

```ini
# /etc/systemd/journald.conf.d/volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
Compress=yes
SystemMaxFileSize=16M
```
<!--
### (Optional) Persisting user data: mount /home from NFS

For my plans I don't want any persistence, but during project testing and debugging it was useful to store some files for later.

While I had this need, I simply mounted the /home directory to a path on the NFS Server, this time as read-write.

The shared OS root stays immutable. To persist user files, mount a separate NFS share at `/home`. Use explicit systemd units (not fstab) so Overlayroot doesn’t rewrite the path and so the mount never blocks boot.

```ini
# /etc/systemd/system/home.mount
[Unit]
Description=Home over NFS
Wants=network-online.target
After=network-online.target
OnFailure=home-mount-debug.service

[Mount]
What=192.168.1.66:/mnt/nfsshare/home
Where=/home
Type=nfs
Options=rw,nfsvers=3,proto=tcp,noatime,soft,timeo=50,retrans=3,nolock
TimeoutSec=30
```

```ini
# /etc/systemd/system/home.automount
[Unit]
Description=Automount /home

[Automount]
Where=/home
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
```

Defer activation until provisioning completes so user creation doesn’t trigger the mount:

```ini
# /etc/systemd/system/home-activate.service
[Unit]
Description=Activate /home automount after provisioning
Wants=cloud-final.service network-online.target
After=cloud-final.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl start home.automount

[Install]
WantedBy=multi-user.target
```

Server‑side, create the export and a default user directory:

```bash
/mnt/nfsshare/home/
/mnt/nfsshare/home/ubuntu  (0700, uid/gid 1000)
``` -->

## Review

- Root is an overlay and writable:
  - `findmnt -no FSTYPE,OPTIONS /` → `overlay rw,...`
- Lower is NFS and read‑only:
  - `findmnt -no FSTYPE,OPTIONS /media/root-ro` → `nfs ...,ro,vers=3,proto=tcp`
- `/home` automount is armed after provisioning:
  - `findmnt /home` → `systemd-1 autofs` before first access; `nfs` after `ls /home`.
- A file in `~ubuntu` appears on the NFS share.

With this setup you get an immutable, shared base OS for all Pis and clean, per‑node ephemeral state - while keeping user data safely on the NFS share.
