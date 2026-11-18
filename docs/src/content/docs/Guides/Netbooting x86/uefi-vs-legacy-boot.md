---
title: UEFI vs Legacy Boot
slug: guides/netbooting-x86/uefi-vs-legacy-boot
description: Getting the firmware to offer a UEFI network boot
draft: false
---

ainur only serves UEFI network boot, and Talos installs in UEFI mode. A machine whose network card only does legacy PXE looks like it's trying, then boots its disk anyway. Here's what to set, once per machine, using an HP ProDesk's *Computer Setup* (F10) as the example.

## Explanation

- **Legacy (BIOS) PXE** runs the network card's old option ROM, and expects a `*.kpxe` program. ainur doesn't offer one.
- **UEFI PXE** needs the network card's UEFI driver loaded. Only then does a *UEFI N/W - IPV4 Network* entry appear in the boot menus.

An HP shipped with legacy support on loads the network card's legacy ROM, so its network boot entry appears under *Legacy Boot Order* only, and the UEFI side never offers one.

## Implementation

### 1. HP Computer Setup (F10)

Under **Advanced**:

- **Option ROM Launch Policy**: set *Configure Option ROM Launch Policy* to **All UEFI**. (*All UEFI Except Video* is for old graphics cards; the ProDesk's built-in graphics doesn't need it.)
- **Secure Boot Configuration**: **Legacy Support Disable and Secure Boot Disable**. Legacy is unused, and Secure Boot would refuse `ipxe.efi`, which isn't signed with a key the firmware trusts.
- **Boot Options**: keep **Network (PXE) Boot** ticked, untick **Fast Boot** (it can skip loading the network driver), and untick **Legacy Boot Order**.

Save and exit (F10). On the next boot the network driver loads, and **UEFI N/W - IPV4 Network - Realtek PCIe GBE Family Controller** appears in F9's boot menu.

### 2. Leave the disk first

Keep the NVMe at the top of the UEFI boot order, and pick the network from F9 when you want it. A blank disk falls through to the network by itself; once Omni has installed Talos, the machine should boot that. Network boot first would run Talos from the network on every boot, not the system Omni installed, and the menu's reset entry would be one keypress away each time.

### 3. Secure Boot, later

Talos does support Secure Boot, with its own signed images and keys enrolled in the firmware, and network boot would need a signed loader in front of iPXE. It's a separate setup, not a firmware switch, and not needed for any of this.

## Next Steps

With the firmware asking, here's what it gets: [Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/).
