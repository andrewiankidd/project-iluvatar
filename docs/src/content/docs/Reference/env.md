---
title: .env Reference
slug: reference/env
description: Every setting in bootstrap/netboot/.env, the one file you edit to bring up the lab.
draft: false
---

Everything the bootstrap needs that isn't in Git lives in `bootstrap/netboot/.env`. Start from `.env.example` next to it, which has the same sections. The file is gitignored: secrets go here, never in the repo.

:::caution[Readable on the LAN]
The bootstrap VM serves the `AINUR_*` and `ARDA_*` values to the Pis over plain HTTP (`/secrets/*.env`) while it runs, the same way it serves the k3s join token. The design trusts the LAN.
:::

Values with a `$` in them (a bcrypt hash) need single quotes: `AINUR_DEX_ADMIN_HASH='$2y$10$...'`. Both the VM's scripts and Docker Compose read the file, and both leave single-quoted values alone.

## Build

| Setting | Default | |
|---|---|---|
| `COMPOSE_PROFILE` | `debian-netboot` | `debian-netboot` builds the image and serves netboot. `debian-sdcard` writes an SD card image to `bootstrap/netboot/download/` instead. `netboot` only serves. |
| `DOWNLOAD_LINK` | Ubuntu 24.04 for Pi | The OS image the build starts from. |
| `ASSETS_DIR` | `ubuntuserver` | Which `assets/` folder (cloud-init and overlays) goes with it. |
| `CLEAN_BOOT_FILES` / `CLEAN_OS_FILES` | `true` / `false` | Start the boot or OS export from scratch on each build. |
| `FORCE_REEXTRACT` | `false` | Extract the downloaded image again even if it was already. |

## Bootstrap VM

| Setting | Default | |
|---|---|---|
| `VM_NAME` | `netboot-$COMPOSE_PROFILE-vm` | The Multipass VM. |
| `VM_OS`, `VM_CPUS`, `VM_MEMORY`, `VM_DISK` | `22.04`, `8`, `4G`, `15G` | Its size. |
| `VM_REBUILD` | `false` | Delete and recreate the VM on the next start. |
| `VM_NETWORK` | the first wired network | The network the VM bridges onto, as `multipass networks` names it. It must be the Pis' LAN. |
| `BOOTSTRAP_IP_ADDRESS` | `192.168.1.66` | The VM's fixed address on the LAN: TFTP, NFS and HTTP for netboot. |
| `NFS_VERSION`, `NFS_EXPORT_0`, `NFS_LOG_LEVEL` | | The VM's NFS server. |

## Pis

Used by [`rebootstrap.sh`](/project-iluvatar/getting-started/rebootstrap-ainur/).

| Setting | Default | |
|---|---|---|
| `PI_HOSTS` | `192.168.1.50 192.168.1.51 192.168.1.52` | The Pis. |
| `PI_USER` | `ubuntu` | Their user. |

## ainur secrets

The builder writes the first three into the Pis' cloud-init. A script in cloud-init makes them all into an `ainur-secrets` Secret in each namespace that reads one (Dex, Argo CD, Omni, Homepage and the in-cluster builder).

| Setting | |
|---|---|
| `AINUR_PI_PASSWORD` | The Pis' `ubuntu` user; also `rebootstrap.sh`'s login. |
| `AINUR_K3S_TOKEN`, `AINUR_K3S_AGENT_TOKEN` | k3s's join tokens, server and agent. |
| `AINUR_DEX_ADMIN_HASH` | bcrypt hash of Dex's `admin@` password: `htpasswd -nbBC 10 "" 'password' \| tr -d ':\n'` |
| `AINUR_OIDC_CLIENT_SECRET` | The client secret Dex shares with Argo CD, Headlamp, Omni and Homepage. |
| `AINUR_HOMEPAGE_AUTH_SECRET` | Homepage's session cookie key, 32 characters or more. |

## arda secrets

Kept on ainur as its `arda-secrets` Secret; once arda is up, a Job hands each to its app there.

| Setting | |
|---|---|
| `ARDA_CLOUDFLARE_API_TOKEN` | Cloudflare token with Zone:DNS:Edit, for external-dns and ddns. |
| `ARDA_CLOUDFLARE_TUNNEL_TOKEN` | The `arda` tunnel's token (`cloudflared tunnel token arda`). |
| `ARDA_MINECRAFT_WHITELIST`, `ARDA_MINECRAFT_BUILDERS` | Minecraft UUIDs, comma-separated: who may join survival, and who may build on creative. |
| `ARDA_DRAGONWILDS_OWNER_ID`, `ARDA_DRAGONWILDS_ADMIN_PASSWORD`, `ARDA_DRAGONWILDS_WORLD_PASSWORD` | The Dragonwilds owner's Player ID, the Server Management password, and an optional join password. |
| `ARDA_BACKUP_ACCESS_KEY_ID`, `ARDA_BACKUP_SECRET_ACCESS_KEY`, `ARDA_BACKUP_ENDPOINT` | S3 keys and endpoint for arda's volume backups to Cloudflare R2 (VolSync, into the `arda-backups` bucket). For an R2 API token: its ID, the SHA-256 of its value, and `https://<account id>.r2.cloudflarestorage.com`. |
| `ARDA_UNIFI_API_KEY`, `ARDA_UNIFI_URL` | A UniFi OS API key (*Settings → Control Plane → Integrations*) for the router's port forwards to arda's games, which ainur's `unifi` CronJob keeps from the Services marked `kidd.network/port-forward: "true"`, and for arda's LAN DNS records (`external-dns-lan`); and the console's address, if not `https://192.168.1.1`. |
| `ARDA_VOLSYNC_PASSWORD` | The restic password for every arda volume's backups: VolSync backs each Longhorn volume up nightly to `arda-backups/volsync/<namespace>/<pvc>` in R2, with the `ARDA_BACKUP_*` keys, and restores it when a fresh cluster creates the volume again. Any long random string. **Lose it and every backup is unreadable**: keep a copy outside the lab. |
