---
title: UEFI vs Legacy Boot
description: Making firmware behave
---

Talos boots happily on either BIOS or UEFI firmware provided you hand it the right iPXE binary. This guide explains what to flip in your x86 nodes so they find the bootstrap services every time.

## Explanation

- **Legacy (BIOS) PXE** expects a `*.kpxe` image delivered over TFTP. Once loaded it can fetch everything else via HTTP.
- **UEFI PXE** speaks the same protocol, but looks for `*.efi` binaries and may prioritise IPv6.

Most small-form-factor desktops ship with both modes enabled. Leaving them on “automatic” works, but explicitly enabling UEFI first keeps boot times consistent and avoids falling back to local disks.

## Implementation

### 1. Configure firmware order

For each node:

1. Enable **Network Stack** (UEFI terminology) or **PXE Boot to LAN** (legacy wording).
2. Set the boot order to `UEFI Network` → `Legacy Network` → everything else. Disable local disks entirely if you want the machines to remain stateless.
3. Turn on **IPv4 only** for PXE. dnsmasq proxy responses only cover IPv4 in this setup.

The exact menu names differ by vendor, but the general recipe is:

- Enable “Network Stack” or “PXE Boot to LAN”.
- Prefer “UEFI IPv4” over legacy PXE.
- Disable local boot devices if you want nodes to remain stateless.

### 2. Match the iPXE entrypoint

The bootstrap TFTP share provides both binaries:

| Firmware | File            | Notes                          |
|----------|-----------------|--------------------------------|
| BIOS     | `undionly.kpxe` | Chainloads `talos.ipxe` script |
| UEFI     | `ipxe.efi`      | Same script, UEFI-friendly     |

dnsmasq automatically selects which filename to offer via Option 67 based on the client’s PXE class. You usually don’t have to hardcode it, but you can override with:

```ini
dhcp-match=set:efi,option:client-arch,7
dhcp-boot=tag:efi,ipxe.efi
dhcp-boot=tag:!efi,undionly.kpxe
```

### 3. Test and capture MAC IDs

Booting once into iPXE gives you the machine’s MAC address. Record it and commit it to the Talos machine config map (or Sidero inventory) so Talos knows which configuration to pull for that hardware class.

## Next Steps

With firmware sorted, the remaining task is to chain Talos into the process: downloading kernel/initrd, serving the `talos.ipxe` script, and presenting machine configs. Continue with [Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/).
