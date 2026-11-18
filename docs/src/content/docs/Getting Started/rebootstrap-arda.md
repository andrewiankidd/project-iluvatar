---
title: 🔁 Re-bootstrapping Arda
slug: getting-started/rebootstrap-arda
description: Putting an x86 machine back into arda, whether this Omni installed it, an earlier one did, or something else entirely.
sidebar:
  order: 6
draft: false
---

> tl;dr - a machine this Omni installed: remove it in Omni. Anything else: network-boot it (F9 → IPv4 network) and pick **Reset system disk**; if this Omni has seen it before, delete it in Omni.

How hard this is depends on who installed what's on the machine's disk, and whether that Omni is still around.

## A machine this Omni installed

Remove it from the cluster in Omni (*Machines*, or its cluster's machine list). Omni resets it properly: Talos wipes its whole system disk and comes back in maintenance mode, and the cluster template allocates it again. Nothing to do at the machine.

## Anything else

That covers:

- **A machine an earlier Omni installed.** Rebuilding ainur starts a new Omni, so the installed Talos holds a join token the new Omni refuses. If `.env` didn't hold the lab CA (`AINUR_LAB_CA_CRT` and `AINUR_LAB_CA_KEY`, see the [.env reference](/project-iluvatar/reference/env/)), ainur also made a new CA, and the installed Talos trusts one nothing serves any more. Its console shows `certificate signed by unknown authority ... "Lab Root CA"`. The old Omni held the only keys to its Talos API, so nothing can reach it over the network.
- **An install Omni didn't make**: an older Talos, an earlier experiment, Windows.

Either way, Talos remembers it was installed in a 1 MB partition called `META`. While `META` is there, Omni treats the machine as installed and tries to *upgrade* it, which can fail over and over (`installer exit code 7`) and hold the machine locked. `META` is in use while Talos runs, so it can't be wiped over the network.

What clears all of it is Talos's own reset, `talos.experimental.wipe=system`: it wipes the whole system disk, `META` included, before anything else runs, then carries on booting the image it came from, with the current CA and join config.

### From the network (recommended)

1. **Network-boot it**: **F9** at power-on, then the **IPv4** network entry (*UEFI N/W - IPV4 Network* on an HP). If there's no such entry, its network card isn't booting in UEFI mode: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).
2. **At the iPXE menu, pick `Talos (Reset system disk: wipes it, then joins Omni)`** within ten seconds. Left alone it boots plain **Talos**, which won't clear `META`.
3. **If this Omni has seen the machine before, delete it in Omni.** The reset also wiped the token that proves the machine is the one Omni knows, so Omni turns it away: its console logs `error provisioning: ... PermissionDenied desc = unauthorized`. Delete it from *Machines* (or `omnictl delete link <its UUID>`) and it registers again within a minute. After ainur has been rebuilt there's nothing to delete.

Then it's a new machine: the cluster template allocates it, Omni installs Talos to the NVMe, and it reboots from the NVMe into the cluster. Its boot order doesn't change.

:::note[Not the installed Talos's reset]
An installed Talos's own boot menu has **Talos (Reset to maintenance mode)**. It wipes the machine's config but boots the same installed image, so after an ainur rebuild it comes back still trusting the old CA, and still can't reach Omni. Use the network boot's reset.
:::

### From a USB stick

For a machine that can't network-boot. Download `http://bootstrap.example.com/talos-media/metal-amd64.iso` again first (ainur refreshes it whenever its CA or join config changes) and write it to the stick.

1. **Get it to boot the stick.** USB above the internal disk in the boot order, or the one-time boot menu (F9 on an HP). If the machine is in Talos maintenance mode and its keyboard doesn't work in the firmware either, run
    ```bash
    ./bootstrap/arda/rebootstrap.sh 192.168.1.238
    ```
    with the address from its console. It wipes the old install's boot partition over the maintenance-mode API, so the disk can't boot and the firmware falls through to the stick. Then Ctrl+Alt+Del. (This only works where maintenance mode is open to the network: not for a machine still configured for an Omni.)
2. **At the stick's boot menu, pick `Talos (Reset system disk)`.** It wipes the disk and boots on into maintenance mode.
3. **If this Omni has seen the machine before, delete it in Omni**, as above.

:::caution[Pull the stick afterwards]
Once it's in the cluster, take the stick out, or put the NVMe first. Booted from the stick, the reset entry is one keypress away, and it wipes the disk.
:::

## Avoiding it next time

- Start a machine from a blank disk, or from one this Omni installed. If it has had anything else on it, pick **Reset system disk** the first time it network-boots.
- Remove machines through Omni rather than wiping them some other way.
