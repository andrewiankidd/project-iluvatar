---
title: 🖥️ Bootstrapping Arda (x86 Cluster)
slug: getting-started/bootstrap-arda
description: Booting the x86 machines into Omni, over the network or from a USB stick, and checking arda comes up.
sidebar:
  order: 3
draft: true
---

> tl;dr - with ainur up, network-boot each x86 machine once (F9 → IPv4 network on an HP). It joins Omni, Omni installs Talos to its NVMe, and arda builds itself.

arda is the x86 cluster, `talos-default`, run by Omni on ainur. Nothing about a machine is configured by hand: what it boots already trusts the lab CA and knows how to reach Omni, and the cluster template decides what each machine becomes.

## Before you start

- **ainur is up**, with every Argo CD app healthy: Omni and the netboot servers run there. See [Bootstrap Ainur](/project-iluvatar/getting-started/bootstrap-ainur/).
- **Each machine boots UEFI, with Secure Boot off.** Talos is installed in UEFI mode and ainur only answers UEFI network boot. On HP machines, see [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/) for the four settings that matter.
- **Disks**: the NVMe is Talos's system disk; a SATA SSD, if there is one, becomes Longhorn's.

## Booting a machine

There are two ways to give a machine its first Talos. They boot the same image, built from the same schematic. **Network boot is the default**: nothing to download or write, and it always serves the current image.

### Network boot (recommended)

1. Power the machine on and open its one-time boot menu (**F9** on an HP).
2. Pick the **IPv4** network entry (*UEFI N/W - IPV4 Network* on an HP).
3. iPXE shows a menu:
    - **Talos**, the default after ten seconds: for a blank disk, or one only Omni has used.
    - **Talos (Reset system disk: wipes it, then joins Omni)**: for a disk with anything else on it, including a Talos from before ainur was rebuilt. It wipes the disk first. See [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/).

Leave the NVMe first in the boot order: network boot is a one-off, picked from F9.

How it works: [Netbooting x86](/project-iluvatar/guides/netbooting-x86/).

### USB stick (alternative)

For a machine that can't network-boot:

1. Download `http://bootstrap.example.com/talos-media/metal-amd64.iso`. ainur builds it from the same schematic and refreshes it whenever that changes, so download it again after ainur has been rebuilt. Don't use Omni's own *Download Installation Media*: its image lacks the lab CA.
2. Write it to a USB stick (Rufus or balenaEtcher) and boot the machine from it.
3. Its boot menu has the same two choices, as **Talos** and **Talos (Reset system disk)**.

Once the machine is in the cluster, take the stick out or put the NVMe first: booted from the stick, the reset entry is one keypress away.

## Joining

Either way, Talos boots in maintenance mode and connects to Omni over SideroLink. The machine appears under *Machines* in `https://omni.example.com` within a minute, and then on its own:

1. **The cluster template allocates it**: the first machine becomes the control plane, every other one a worker.
2. **Omni installs Talos to the NVMe** from the same schematic, and the machine reboots from the NVMe.
3. **`arda-disks`** on ainur wipes the SATA SSD if it holds old partitions, and labels the node so Longhorn uses it.
4. **`arda-bootstrap`** on ainur, once `talos-default` is up, installs Argo CD on arda and points it at `src/manifests/arda`, with each app's `ARDA_*` secret from `.env`.

## Checking it

- **Omni**: `talos-default` is *Running*, with every machine *Ready*.
- **ainur's Argo CD**: `sidero-omni` is *Healthy*. It shows *Progressing* until `arda-bootstrap` has finished.
- **arda's Argo CD** (with the kubeconfig from Omni's *Download kubeconfig*): every app *Synced* and *Healthy*.
- **The sites**: `https://minecraft.example.com` and the rest answer on the LAN, through arda's address, `192.168.1.58`.

## If a machine doesn't show up

- **It went straight to its disk**: its network card isn't booting in UEFI mode. [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).
- **Its console says `certificate signed by unknown authority ... "Lab Root CA"`**: it's running an image made for an earlier lab CA. Network-boot it and pick **Reset system disk**.
- More in [Serving Talos via PXE: Troubleshooting](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/#troubleshooting).
