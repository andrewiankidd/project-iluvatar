---
title: 🔁 Re-bootstrapping Arda
slug: getting-started/rebootstrap-arda
description: Putting an x86 machine back into arda, whether Omni installed it or something else did.
sidebar:
  order: 6
draft: false
---

> tl;dr - a machine Omni installed: remove it in Omni. Anything else: boot the stick, pick **Reset system disk**, and if Omni has seen it before, delete it in Omni.

How hard this is depends on who installed what's on the machine's disk.

## A machine Omni installed

Remove it from the cluster in Omni (*Machines*, or its cluster's machine list). Omni resets it properly: Talos wipes its whole system disk and comes back in maintenance mode, and the cluster template allocates it again. Nothing to do at the machine.

## Anything else

An install Omni didn't make (an older Talos, an earlier experiment, Windows) gets in the way three times over:

- **It boots ahead of the USB stick**, so the stick never runs.
- **Talos remembers it was installed** in a 1 MB partition called `META`. While `META` is there, the ISO refuses to go on (*"Talos is already installed to disk but booted from another media"*), and Omni treats the machine as installed and tries to *upgrade* it, which fails over and over (`installer exit code 7`) and holds the machine locked. Wiping the other partitions doesn't help: `META` is in use while Talos runs, so it can't be wiped over the network.
- **An older Talos can't take the cluster's config**, so it can't join that way either: Omni's config for a newer Talos has documents the old one doesn't know.

What clears all of it is Talos's own reset, from the stick's boot menu: it wipes the whole system disk, `META` included, before anything else runs.

1. **Get it to boot the stick.** USB above the internal disk in the BIOS boot order (F10 on an HP), or the one-time boot menu (F9). If the keyboard doesn't work there either, run
    ```bash
    ./bootstrap/arda/rebootstrap.sh 192.168.1.238
    ```
    with the address from its console. It wipes the old install's boot partition over the maintenance-mode API, so the disk can't boot and the firmware falls through to the stick. Then Ctrl+Alt+Del.
2. **At the stick's boot menu, pick `Talos (Reset system disk)`.** Unlike an old install's menu, this one takes keys through a JetKVM. It wipes the disk and boots on into maintenance mode.
3. **If Omni has seen this machine before, delete it in Omni.** The reset also wiped the token that proves the machine is the one Omni knows, so Omni turns it away: its console logs `error provisioning: ... PermissionDenied desc = unauthorized`. Delete it from *Machines* (or `omnictl delete link <its UUID>`) and it registers again within a minute.

Then it's a new machine: the cluster template allocates it, Omni installs Talos to the NVMe, and it reboots into the cluster.

:::caution[Pull the stick afterwards]
Once it's in the cluster, take the stick out, or put the NVMe first. Booted from the stick, the reset entry is one keypress away, and it wipes the disk.
:::

## Avoiding it next time

Start the machine from a blank disk, or from one Omni installed. If a ProDesk has had anything else on it, do the reset from the stick before it ever joins Omni, and steps 1 and 3 never come up.
