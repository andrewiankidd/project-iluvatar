---
title: 🔁 Re-bootstrapping Arda
slug: getting-started/rebootstrap-arda
description: Putting an x86 machine back into arda, whether Omni installed it, an earlier Omni did, or something else did.
sidebar:
  order: 6
draft: false
---

> tl;dr - the Omni that installed it is still running: remove it in Omni. Anything else: network boot it (F9 on an HP) and pick **Talos (Reset system disk)**.

How hard this is depends on who installed what's on the machine's disk, and whether they're still around.

## Omni installed it, and that Omni is still running

Remove it from the cluster in Omni (*Machines*, or its cluster's machine list). Omni resets it properly: Talos wipes its whole system disk and comes back in maintenance mode, and the cluster template allocates it again. Nothing to do at the machine.

## Anything else

That covers an install by an Omni that's gone (ainur was rebuilt, and Omni with it), one made under a different lab CA, an older Talos, an earlier experiment, or Windows. None of them can be fixed over the network:

- **The old install only takes orders from the Omni that installed it.** Its keys went with that Omni, so nothing else can tell it to reset.
- **It trusts the CA it was installed under.** If that CA has changed, the console shows `x509: certificate signed by unknown authority ... "Lab Root CA"` on every SideroLink attempt, and maintenance mode only listens over that link.
- **Talos remembers it was installed**, in a 1 MB partition called `META`. While `META` is there, Omni treats the machine as installed and tries to *upgrade* it, which can fail over and over (`installer exit code 7`) and hold the machine locked.

The wrong CA, on the machine's console, every few seconds:

![Talos console: SideroLink failing with x509 certificate signed by unknown authority, Lab Root CA](../../../assets/docs/troubleshooting/talos-siderolink-unknown-ca.png)

And the failed upgrades:

![Talos console: installer container exited with code 7, over and over](../../../assets/docs/troubleshooting/talos-installer-exit-code-7.png)

What clears all of it is Talos's own reset, which wipes the whole system disk, `META` included, before anything else runs. ainur serves it on the network, so there's no USB stick to make:

1. **Once per machine, set up its firmware for UEFI network boot**: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/) has the HP settings.
2. **Restart it and press F9** for the one-time boot menu. Pick **UEFI N/W - IPV4 Network**.
3. **At ainur's menu, pick `Talos (Reset system disk: wipes it, then joins Omni)`** within ten seconds. Left alone, it boots the plain `Talos` entry, which doesn't wipe anything. On a machine with Talos still on its disk, the plain entry stops there: *Talos is already installed to disk but booted from another media*. Restart and pick the reset entry, or boot it from its disk.

    ![Talos console: already installed to disk but booted from another media, talos.halt_if_installed is set](../../../assets/docs/troubleshooting/talos-halt-if-installed.png)

![ainur's network boot menu, with the reset entry selected](../../../assets/docs/guides/netbooting-x86/ipxe-reset-menu.png)

Talos wipes the disk, boots on into maintenance mode with the current lab CA and Omni's join token, and registers itself. Then it's a new machine: the cluster template allocates it, Omni installs Talos to the NVMe, and it reboots into the cluster. The first machine becomes the control plane, every later one a worker.

If Omni has seen this exact machine before (the same Omni, not a rebuilt one), the reset also wiped the token that proves it's the machine Omni knows, so Omni turns it away: its console logs `error provisioning: ... PermissionDenied desc = unauthorized`. Delete it from *Machines* (or `omnictl delete link <its UUID>`) and it registers again within a minute.

### The installed system's own menu

An install Omni made has a boot menu of its own, with **Reset to maintenance mode**:

![The installed Talos boot menu](../../../assets/docs/guides/netbooting-x86/talos-installed-boot-menu.png)

That wipes the machine's config but keeps the install, and with it the CA and Omni address the install was made with. It helps when the same Omni is still there. After a rebuild it doesn't: the machine comes back in maintenance mode still trusting the old CA, and still unreachable.

### Without network boot

If a machine can't network boot, the same reset is on the Talos ISO's boot menu as **Talos (Reset system disk)**. Write the ISO ainur caches (`talos-iso`) to a stick and boot that instead. An old install that boots ahead of the stick can have its boot partition wiped from its maintenance-mode console address with `./bootstrap/arda/rebootstrap.sh <address>`, so the firmware falls through to the stick. Take the stick out once the machine is in the cluster: booted from it, the reset entry is one keypress away.

## Keeping it rare

- **ainur's lab CA comes from `.env`** (`AINUR_LAB_CA_CRT`, `AINUR_LAB_CA_KEY`), so a rebuilt ainur keeps the CA every machine already trusts. Leave them empty and every rebuild makes a new CA, and every arda machine needs the reset above.
- **Omni's data survives a rebuild**: it's kept at a fixed path on valar-50's NVMe, and backed up to R2 every night for when the NVMe itself is new. A rebuilt ainur comes back with the same Omni, which still knows every machine, so none of them need the reset above.
- **arda's volumes come back by themselves**: each is created from its latest nightly backup in R2 (VolSync), so a rebuilt arda has its worlds, notes and documents again. Only what changed since 03:00 is lost.
- **Start a machine from a blank disk**, or from one this Omni installed, and none of this comes up.
