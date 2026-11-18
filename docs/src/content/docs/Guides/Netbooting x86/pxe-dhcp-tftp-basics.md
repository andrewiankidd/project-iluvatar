---
title: PXE / DHCP / TFTP Basics
slug: guides/netbooting-x86/pxe-dhcp-tftp-basics
description: Wiring Talos into the broadcast storm
draft: true
---

How ainur offers a network boot to the x86 machines without taking DHCP over from the router, and without getting in the way of the Pis, which netboot from the same servers.

## Explanation

Network boot on x86 has three moving parts:

1. **DHCP** gives the machine an address and tells its firmware where to find a boot program.
2. **TFTP** serves that boot program: here iPXE, which knows how to fetch an operating system over HTTP(S).
3. **HTTP(S)** serves the rest: the iPXE script, then the Talos kernel and initramfs.

The router keeps doing DHCP. A second DHCP server in *proxy* mode, dnsmasq, listens to the same broadcasts and answers only the boot part, with no addresses of its own. The machine merges the two answers.

The Pis don't use it. Their EEPROM bootloader takes the TFTP server from the router's DHCP option 66 (ainur's VIP once ainur is up) and fetches its boot files directly. The proxy only answers x86-64 UEFI PXE clients, so the two never meet.

## Implementation

`src/manifests/ainur/pi-netboot/proxy-dhcp.yaml` runs dnsmasq on valar-50, on the host network so it sees the broadcasts:

```text
--port=0                                   no DNS
--dhcp-range=192.168.1.0,proxy,255.255.255.0   proxy only: no leases
--dhcp-userclass=set:ipxe,iPXE             tag requests that come from iPXE
--pxe-service=tag:!ipxe,x86-64_EFI,Talos,ipxe.efi,192.168.1.59
--pxe-service=tag:ipxe,x86-64_EFI,Talos,http://192.168.1.59/talos/boot.ipxe
```

- **Firmware asking** (no iPXE tag) is told to fetch `ipxe.efi` by TFTP from the VIP.
- **iPXE asking** (the same machine, a moment later) is told to fetch `boot.ipxe` over HTTP. Without the tag it would be handed `ipxe.efi` again and loop.
- **Only `x86-64_EFI`**: no legacy BIOS entry, so no `undionly.kpxe`. See [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).

TFTP (`tftp-deployment.yaml`) serves the Pis' boot files and `ipxe.efi` from one directory. `ipxe.efi` comes from the dnsmasq image: an init container copies it in among the Pi files, and the Pi image builder leaves it out of its `--delete` syncs.

## Checking it

From any Linux machine on the LAN (`curl` speaks TFTP):

```bash
curl -s -o /tmp/ipxe.efi tftp://192.168.1.59/ipxe.efi && ls -l /tmp/ipxe.efi   # about 1.1 MB
curl -s http://192.168.1.59/talos/boot.ipxe                                      # the menu
```

Then network-boot a machine and watch dnsmasq offer it `ipxe.efi`:

```bash
kubectl -n ainur-netboot logs deploy/proxy-dhcp -f | grep -A6 PXEClient
```

## Next Steps

[UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/): getting the machine to ask.
