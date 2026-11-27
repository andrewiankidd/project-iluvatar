---
title: PXE / DHCP / TFTP Basics
slug: guides/netbooting-x86/pxe-dhcp-tftp-basics
description: Offering a boot to x86 machines without taking over the router's DHCP
draft: false
---

The router keeps doing DHCP. ainur adds just the boot answer for x86 machines, from a proxy DHCP, and serves the first file they need over TFTP.

## Explanation

UEFI network boot needs three things:

1. **DHCP**, for an address and for where to boot from.
2. **TFTP**, for a small first program. Here that's iPXE (`ipxe.efi`), which can speak HTTP and HTTPS for everything after it.
3. **HTTP(S)**, for the boot script, then the Talos kernel and initramfs.

dnsmasq in *proxy* mode answers the same DHCP broadcast as the router, but hands out no addresses: its reply only carries the boot details. So the router stays in charge of addresses, and nothing on it changes.

The Pis netboot too, and are untouched by it. They find their TFTP server from DHCP option 66, which the router sets to the VIP, and the proxy only answers clients announcing themselves as x86-64 UEFI.

## Implementation

### 1. The proxy DHCP

`src/manifests/ainur/pi-netboot/proxy-dhcp.yaml` runs dnsmasq on valar-50's host network, beside the VIP:

```
--port=0                                   no DNS
--dhcp-range=192.168.1.0,proxy             proxy mode: no addresses
--dhcp-userclass=set:ipxe,iPXE             tag requests from iPXE itself
--pxe-service=tag:!ipxe,x86-64_EFI,Talos,ipxe.efi,192.168.1.59
--pxe-service=tag:ipxe,x86-64_EFI,Talos,http://192.168.1.59/talos/boot.ipxe
```

The firmware's first request gets `ipxe.efi` over TFTP. Once iPXE is running it asks again, and this time gets the HTTP URL of the boot script.

### 2. `ipxe.efi` over TFTP

`src/manifests/ainur/pi-netboot/tftp-deployment.yaml` serves the Pis' boot files from the `pi-netboot-boot` volume. An init container copies `ipxe.efi` (from the dnsmasq image, iPXE 2.0 with HTTPS) into the same volume, and the image builder's sync into it skips `/ipxe.efi`, so a rebuild of the Pi image doesn't delete it.

:::note
`ipxe.efi` used to be mounted over the volume as a single file. When the volume moved from Longhorn to a local directory, the builder's `rsync --delete` removed that mount point, which unmounts it, and x86 machines got *File not found*. Copied in among the boot files, it stays.
:::

On the machine's console, the firmware's PXE gets `ipxe.efi` from the VIP, and iPXE takes over:

![The firmware's PXE downloading ipxe.efi from 192.168.1.59, then iPXE starting](../../../../assets/docs/guides/netbooting-x86/pxe-to-ipxe-handoff.png)

### 3. Checking it

From any Linux machine on the LAN:

```bash
curl -s -o /tmp/ipxe.efi tftp://192.168.1.59/ipxe.efi && ls -l /tmp/ipxe.efi
curl http://192.168.1.59/talos/boot.ipxe
```

The first should be about 1.1 MB, the second a short iPXE menu. The proxy DHCP logs every PXE request it answers:

```bash
kubectl -n ainur-netboot logs deploy/proxy-dhcp | grep -A8 PXEClient
```

A machine trying to boot shows `vendor class: PXEClient:Arch:00007` (x86-64 UEFI), then `bootfile name: ipxe.efi`. TFTP logs each request in turn, with `sending NAK (1, File not found)` if the file isn't there.

## Next Steps

With the server side answering, the machines have to actually ask: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).
