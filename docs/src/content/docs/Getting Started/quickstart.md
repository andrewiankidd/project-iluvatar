---
title: ⚡ Quickstart
slug: getting-started/quickstart
description: The whole bring-up on one page, from an empty network to Talos machines joining Omni, with links out for the detail.
sidebar:
  order: 0
draft: false
---

> tl;dr - clone, fill in `.env`, start the bootstrap VM, netboot the Pis, then network-boot the x86 machines from ainur. Both clusters can also start from an SD card or USB stick, but netboot is the default.

The examples use `example.com`. This repo uses `kidd.network`; swap in your own domain. Don't own one? Your router's local DNS can make one up for the LAN (see [Network](#network)).

## Setup

1. Clone the repo:
    ```bash
    git clone https://github.com/andrewiankidd/project-iluvatar.git
    ```
2. Copy `bootstrap/netboot/.env.example` to `bootstrap/netboot/.env` and fill it in. Every setting is explained in the [.env reference](/project-iluvatar/reference/env/). Leave `AINUR_LAB_CA_CRT` and `AINUR_LAB_CA_KEY` empty the first time: ainur makes the lab CA, and you copy it in once it's up, so every rebuild after keeps it.
3. Start the bootstrap VM, which builds the Pi image and serves it:
    ```bash
    ./bootstrap/netboot/vm/start.sh
    ```
    On Windows, run it from Git Bash. It needs [Multipass](https://multipass.run/) (and Docker for the helper scripts). The first time, Multipass asks to create a network switch: answer `yes`. More in [Bootstrap VM](/project-iluvatar/architecture/bootstrap-vm/).

## Network

On your router (the examples are UniFi's names):

- **TFTP server (DHCP option 66)**: the bootstrap VM's `BOOTSTRAP_IP_ADDRESS` for the first bootstrap.
- **DHCP DNS**: the router itself (UniFi: *Auto DNS Server*), so the LAN uses its local records.

On UniFi, put an API key in `.env` (`ARDA_UNIFI_API_KEY`, see the [.env reference](/project-iluvatar/reference/env/)) and the rest keeps itself: once ainur is up, its `unifi` CronJob points option 66 at ainur's VIP (`192.168.1.59`) and keeps `example.com` and `*.example.com → 192.168.1.59` in local DNS; arda's sites get exact names to arda (`192.168.1.58`) of their own, and its games their port forwards. `rebootstrap.sh` moves option 66 back to the VM when it needs to. That's what makes every `*.example.com` name work on the LAN, with or without the internet.

On another router, set those yourself: option 66 to ainur's VIP once ainur is up, and the two DNS records.

### Netboot (recommended)

- Set each Pi's bootloader to try the network: [Preparing Pi For Netboot](/project-iluvatar/guides/netbooting-raspberry-pi/pi-prep/). The VM serves the image over TFTP, NFS and HTTP; once ainur is up, ainur serves it itself.

### Or an SD card

One Pi can run from an SD card, so ainur can come up with nothing else on the network. Either:

- **Let netboot write it**: put a blank card in a netbooting Pi. It flashes the card with the current image and reboots onto it.
- **Or flash it yourself**: set `COMPOSE_PROFILE=debian-sdcard` in `.env` and start the VM. The image lands in `bootstrap/netboot/download/`; write it with Raspberry Pi Imager or balenaEtcher and put the card in the Pi.

To move that Pi onto a newer build later, see [Re-bootstrapping Ainur](/project-iluvatar/getting-started/rebootstrap-ainur/).

## Booting ainur

Power the Pis on. On first boot each one:

1. Fetches its kernel over TFTP and runs from an NFS root in RAM (or from its SD card).
2. Runs cloud-init from the VM: hostname, its NVMe (persistent volumes, on the k3s server), and the lab CA.
3. Elects a leader. The first Pi becomes the k3s server, the rest join as agents.
4. Installs cert-manager, trust-manager and Argo CD, plus the `AINUR_*` secrets from `.env`.
5. Lets Argo CD bring up the rest from Git: Dex, Headlamp, Omni, Homepage, and the netboot stack, so ainur now serves its own netboot.

Then check:

- **`https://cert.example.com`**: install the lab CA on your devices so the browser trusts everything else.
- **`https://argocd.example.com`**: log in with Dex. Every app should reach *Healthy*.
- **`https://homepage.example.com`** and **`https://userpage.example.com`**: the public and logged-in service lists.

More: [Bootstrap Ainur](/project-iluvatar/getting-started/bootstrap-ainur/), [Diskless Pi Netboot](/project-iluvatar/guides/netbooting-raspberry-pi/).

## Omni and arda

Omni runs on ainur and manages the x86 Talos cluster, `talos-default`.

1. **Log in** at `https://omni.example.com` with Dex.
2. **On the machine's firmware**: UEFI boot, Secure Boot off, and the network card's UEFI driver loaded so a UEFI **IPv4** network entry appears. On an HP that's four settings: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).
3. **Network-boot it**: the one-time boot menu (F9 on an HP), then the **IPv4** network entry. ainur's iPXE menu boots **Talos** after ten seconds. A machine that has had anything else installed (another OS, or a Talos from before ainur was rebuilt) needs **Reset system disk** from that menu instead; see [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/).
4. **It joins Omni** and shows under *Machines*. The cluster template makes the first one the control plane and the rest workers. Omni installs Talos to the NVMe and reboots it from there.
5. **arda bootstraps itself**: once `talos-default` is up, a Job on ainur installs Argo CD there and points it at `src/manifests/arda`, handing each app its `ARDA_*` secret from `.env`.

**Or a USB stick**, for a machine that can't network-boot: ainur serves the same image as `http://bootstrap.example.com/talos-media/metal-amd64.iso`, with the lab CA and Omni's join settings inside (Omni's own *Download Installation Media* lacks the lab CA). Write it with Rufus or balenaEtcher and boot from it; once the machine has joined, pull the stick or put the NVMe first.

More: [Bootstrapping Arda](/project-iluvatar/getting-started/bootstrap-arda/), [Netbooting x86](/project-iluvatar/guides/netbooting-x86/).
