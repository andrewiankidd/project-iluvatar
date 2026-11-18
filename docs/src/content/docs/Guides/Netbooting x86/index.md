---
title: Netbooting x86
slug: guides/netbooting-x86
description: Talos over the wire, served by the Pis
draft: false
---

arda's x86 machines boot Talos from the network, served by ainur, the Pi cluster. No USB sticks, nothing configured per machine: set the firmware once, press F9, and the machine lands in Omni already trusting the lab CA. The same menu can also wipe a machine that an earlier Omni installed and put it back into arda.

<details>
    <summary>What is PXE?</summary>

> PXE stands for "Preboot Execution Environment." It is a standard that allows a computer to boot and run an operating system over a network, without the need for a local storage device like a hard drive or a USB drive.
>
> PXE is commonly used in enterprise environments, data centers, and for large-scale deployment of operating systems. It enables network booting by providing a set of protocols and services that allow a computer to request and receive an operating system image from a server over the network.
>
>  -- ChatGPT 🤖
</details>

## Prerequisites

:::tip
This reuses the netboot stack that already serves the Raspberry Pis ([Netbooting Pi from Kubernetes](/project-iluvatar/guides/netbooting-pi-from-kubernetes/)): the same VIP, TFTP and HTTP servers. x86 adds a proxy DHCP and a different payload.
:::

- ainur up, with its netboot stack serving on the VIP, 192.168.1.59.
- Omni running on ainur. The boot image carries its join config.
- x86 machines that can UEFI network boot over IPv4. Most can; some need a firmware setting first.

## How it fits together

1. The machine's firmware broadcasts for DHCP. The router gives it an address as usual; ainur's proxy DHCP adds where to boot from.
2. The firmware fetches `ipxe.efi` over TFTP from the VIP, and iPXE fetches `boot.ipxe` over HTTP.
3. `boot.ipxe` is a two-entry menu: Talos, or Talos that wipes the system disk first. Either way the kernel and initramfs come from the Talos Image Factory, built with the lab CA and Omni's join config inside.
4. Talos registers with Omni, and Omni's cluster template takes it from there: installs Talos to the NVMe and adds it to arda.

## The guides

- [PXE / DHCP / TFTP Basics](/project-iluvatar/guides/netbooting-x86/pxe-dhcp-tftp-basics/): the proxy DHCP and TFTP on ainur, and why the Pis don't notice.
- [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/): the firmware settings, with an HP ProDesk as the example.
- [Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/): the image, the menu, and getting it to trust the lab CA.
