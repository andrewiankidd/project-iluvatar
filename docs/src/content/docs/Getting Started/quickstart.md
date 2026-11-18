---
title: ⚡ Quickstart
slug: getting-started/quickstart
description: The whole bring-up on one page, from an empty network to Talos machines joining Omni, with links out for the detail.
sidebar:
  order: 0
draft: false
---

> tl;dr - clone, fill in `.env`, start the bootstrap VM, boot the Pis, then boot the x86 machines from the USB stick ainur builds for you.

The examples use `example.com`. This repo uses `kidd.network`; swap in your own domain. Don't own one? Your router's local DNS can make one up for the LAN (see [Network](#network)).

## Setup

1. Clone the repo:
    ```bash
    git clone https://github.com/andrewiankidd/project-iluvatar.git
    ```
2. Copy `bootstrap/netboot/.env.example` to `bootstrap/netboot/.env` and fill it in. Every setting is explained in the [.env reference](/project-iluvatar/reference/env/).
3. Start the bootstrap VM, which builds the Pi image and serves it:
    ```bash
    ./bootstrap/netboot/vm/start.sh
    ```
    On Windows, run it from Git Bash. It needs [Multipass](https://multipass.run/) (and Docker for the helper scripts). The first time, Multipass asks to create a network switch: answer `yes`. More in [Bootstrap VM](/project-iluvatar/architecture/bootstrap-vm/).

## Network

On your router (the examples are UniFi's names):

- **TFTP server (DHCP option 66)**: the bootstrap VM's `BOOTSTRAP_IP_ADDRESS` while bootstrapping. Once ainur is up it serves its own netboot from its VIP (`192.168.1.59`); point option 66 there.
- **DNS**: a local record `*.example.com → 192.168.1.59`, and DHCP handing out the router as the DNS server (UniFi: *Auto DNS Server*). That's what makes every `*.example.com` name work on the LAN, with or without the internet.

### If the Pis boot from the network

- Set each Pi's bootloader to try the network: [Preparing Pi For Netboot](/project-iluvatar/guides/netbooting-raspberry-pi/pi-prep/).

### If a Pi boots from an SD card

One Pi can run from an SD card, so ainur can come up with nothing else on the network. Either:

- **Let netboot write it**: put a blank card in a netbooting Pi. It flashes the card with the current image and reboots onto it.
- **Or flash it yourself**: set `COMPOSE_PROFILE=debian-sdcard` in `.env` and start the VM. The image lands in `bootstrap/netboot/download/`; write it with Raspberry Pi Imager or balenaEtcher and put the card in the Pi.

To move that Pi onto a newer build later, see [Re-bootstrapping Ainur](/project-iluvatar/getting-started/rebootstrap-ainur/).

## Booting ainur

Power the Pis on. On first boot each one:

1. Fetches its kernel over TFTP and runs from an NFS root in RAM (or from its SD card).
2. Runs cloud-init from the VM: hostname, its NVMe for Longhorn, and the lab CA.
3. Elects a leader. The first Pi becomes the k3s server, the rest join as agents.
4. Installs cert-manager, trust-manager and Argo CD, plus the `AINUR_*` secrets from `.env`.
5. Lets Argo CD bring up the rest from Git: Longhorn, Dex, Headlamp, Omni, Homepage, and the netboot stack, so ainur now serves its own netboot.

Then check:

- **`https://cert.example.com`**: install the lab CA on your devices so the browser trusts everything else.
- **`https://argocd.example.com`**: log in with Dex. Every app should reach *Healthy*.
- **`https://homepage.example.com`** and **`https://userpage.example.com`**: the public and logged-in service lists.

More: [Bootstrap Ainur](/project-iluvatar/getting-started/bootstrap-ainur/), [Diskless Pi Netboot](/project-iluvatar/guides/netbooting-raspberry-pi/).

## Omni and arda

Omni runs on ainur and manages the x86 Talos cluster, `talos-default`.

1. **Log in** at `https://omni.example.com` with Dex.
2. **Get the USB image** from `http://bootstrap.example.com/talos-media/metal-amd64.iso`. ainur builds it for you, with the lab CA and Omni's join settings already inside. Don't use Omni's own *Download Installation Media*: its image lacks the lab CA.
3. **Write it to a USB stick** (Rufus or balenaEtcher).
4. **On the machine**: Secure Boot off, USB first in the boot order. Boot it; no screen needed. If it has had anything else installed (an older Talos, Windows), pick **Reset system disk** at the stick's boot menu first; see [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/).
5. **It joins Omni** and shows under *Machines*. The cluster template makes the first one the control plane and the rest workers. Omni installs Talos to the NVMe and reboots it; if it boots the stick again, put the NVMe first or pull the stick.
6. **arda bootstraps itself**: once `talos-default` is up, a Job on ainur installs Argo CD there and points it at `src/manifests/arda`, handing each app its `ARDA_*` secret from `.env`.

Booting the x86 machines over the network instead is covered in [Netbooting x86](/project-iluvatar/guides/netbooting-x86/).
