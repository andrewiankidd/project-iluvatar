---
title: UEFI vs Legacy Boot
slug: guides/netbooting-x86/uefi-vs-legacy-boot
description: Making firmware behave
draft: true
---

ainur only answers **UEFI** network boot. Talos installs in UEFI mode, the proxy DHCP only offers `ipxe.efi` to x86-64 UEFI clients, and nothing here needs legacy BIOS. So the one firmware job is making sure the machine's network card can boot in UEFI mode, which on a second-hand desktop it often can't out of the box.

## Explanation

A network card can boot in two ways, and the firmware loads a driver (an *option ROM*) for one or the other:

- **Legacy (BIOS) PXE** uses the card's legacy option ROM and expects a `*.kpxe` boot file. It appears in the firmware's *legacy* boot order.
- **UEFI PXE** uses the card's UEFI driver and expects a `*.efi` file. It appears in the *UEFI* boot order, usually as *IPv4 Network* and *IPv6 Network*.

A machine with legacy support switched on may load only the legacy ROM. Then its network card shows up in the legacy boot order and nowhere in the UEFI one, and a UEFI boot skips straight past it to the disk, with no request ever reaching the proxy DHCP. That's exactly what the first ProDesk did.

## Implementation

### HP ProDesk / EliteDesk

In *Computer Setup* (F10 at power-on, or **Reboot Into Firmware Interface** from an installed Talos's boot menu):

1. **Advanced → Option ROM Launch Policy → Configure Option ROM Launch Policy: All UEFI.** This loads the network card's UEFI driver.
2. **Advanced → Secure Boot Configuration → Configure Legacy Support and Secure Boot: Legacy Support Disable and Secure Boot Disable.** UEFI only, and no Secure Boot: the `ipxe.efi` served isn't signed with a key the firmware trusts, and the Talos images aren't the Secure Boot ones.
3. **Advanced → Boot Options:** tick **Network (PXE) Boot**, untick **Fast Boot** (it can skip loading the network driver), and leave **Legacy Boot Order** unticked.
4. **F10** to save. After the next restart, the UEFI boot order and the **F9** boot menu list **UEFI N/W - IPV4 Network** for the onboard card.

Leave the NVMe first in the boot order. A machine that network-booted every time would run Talos from the network instead of from the install Omni puts on its disk. Network boot is for when you choose it: **F9 → UEFI N/W - IPV4 Network**, then the menu (see [Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/)).

### Other machines

The names differ, the recipe doesn't:

- Load the network card's **UEFI** driver: "Network Stack", "PXE OpROM: UEFI", "Option ROM policy: UEFI".
- **Turn off CSM / legacy support**, so the legacy ROM doesn't take its place.
- **Secure Boot off.**
- Check the **UEFI** boot order or one-time boot menu for an **IPv4** network entry. IPv6 isn't answered here.

## Checking it

Pick the IPv4 network entry and watch the proxy DHCP:

```bash
kubectl -n ainur-netboot logs deploy/proxy-dhcp | grep PXEClient
```

A UEFI client shows as `PXEClient:Arch:00007`, followed by the offer of `ipxe.efi` from `192.168.1.59`. No `PXEClient` line at all means the firmware is still not asking over UEFI.

## Next Steps

[Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/): what the machine gets once it asks.
