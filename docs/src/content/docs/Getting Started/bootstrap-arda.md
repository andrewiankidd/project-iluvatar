---
title: 🖥️ Bootstrapping Arda (x86 Cluster)
slug: getting-started/bootstrap-arda
description: Joining x86 machines to arda by network boot, and checking the cluster comes up.
sidebar:
  order: 3
draft: false
---

arda is the x86 cluster: HP ProDesks running Talos, managed by Omni on ainur. Nothing about it is set up by hand. A machine network boots from ainur, registers with Omni, and Omni builds the cluster from the template in `src/manifests/ainur/sidero-omni/omni-config/`.

## Before the first machine

- **ainur is up**, with Omni, the netboot stack and the `talos-schematic` Job done. `curl http://192.168.1.59/talos/boot.ipxe` should print a short iPXE menu.
- **Each machine's firmware does UEFI network boot**: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/). Once per machine.
- **The disk is blank, or Omni installed it.** Anything else, see [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/) first.

## Joining a machine

1. Power it on and press **F9**, then pick **UEFI N/W - IPV4 Network**. (A blank disk falls through to the network by itself.)
2. ainur's menu boots **Talos** after ten seconds. Talos runs in RAM, already trusting the lab CA and holding Omni's join token ([how](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/)), and registers itself.
3. Omni allocates it from the cluster template:
    - **The first machine becomes the control plane**, which also runs workloads.
    - **Every machine after it becomes a worker.** Workers have their own machine class, which a machine joins only once the control plane has its machine (ainur's `arda-disks` CronJob labels it, every ten minutes), so the order never depends on which set Omni fills first.
4. Omni installs Talos to the NVMe and reboots it. Leave the NVMe first in the boot order: it boots from disk from then on.
5. `arda-disks` gets the SATA SSD ready for Longhorn, wiping it if it arrives with old partitions.

## Checking the cluster

- **Omni**, at `https://omni.kidd.network`: the machine under *Machines*, connected, and `talos-default` healthy.
- **The `arda-bootstrap` Job** on ainur (`kubectl -n ainur-sidero-omni logs job/arda-bootstrap`): it waits for `talos-default`, then installs Argo CD on arda, with the `arda-secrets` and the app-of-apps for `src/manifests/arda`.
- **arda's Argo CD** brings up the rest: MetalLB on 192.168.1.58, Traefik, Longhorn, VolSync and the games.

## When it doesn't

- **Nothing happens on F9's network entry**, or the machine goes straight back to its disk: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/), and the troubleshooting in [Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/).
- **It registers, but its config fails** (Omni shows a config error on the machine): a patch in the cluster template doesn't fit that machine's role. Patches only for control planes go under `ControlPlane:` in the template, not at the top.
- **`x509: certificate signed by unknown authority`** on its console: it was installed under another lab CA. [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/).
