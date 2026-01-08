---
title: Netbooting x86
slug: guides/netbooting-x86
description: Talos over the wire
draft: true
---

So you have a pile of diskless (or soon-to-be diskless) x86 boxes and want them to boot a modern, immutable OS without ever touching a USB stick. This section walks through the PXE flow that hands Talos Linux to generic x86 hardware.

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
If you are reusing the same netboot stack that serves Raspberry Pi devices, start with the [Pi netboot guides](/project-iluvatar/guides/netbooting-raspberry-pi/). The x86 steps below reuse the same dnsmasq, TFTP, and image-hosting services—only the payload changes.
:::

- dnsmasq (or another DHCP forwarder) capable of proxy-DHCP, so your existing router keeps handing out leases while PXE options are injected.
- TFTP service offering an iPXE shim plus the Talos kernel and initramfs.
- HTTP server for the heavier Talos artefacts and machine configuration YAML.
- Talos machine configurations generated with `talosctl gen config` and stored somewhere the nodes can reach—Git + static hosting works well.

## Explanation

x86 network boot follows the classic PXE handshake:

1. The node asks the network for DHCP information.
2. dnsmasq responds with normal leases from your router, *plus* Option 66/67 telling the firmware to chainload iPXE from the bootstrap server.
3. The downloaded iPXE script boots the Talos kernel (`vmlinuz`) and initramfs (`initramfs.xz`) via TFTP and HTTP.
4. Talos brings up networking, grabs its machine config from HTTP, and joins the desired Kubernetes control plane.

Because Talos is immutable and lives entirely in RAM, nodes can boot, reprovision, or be replaced without touching local disks—perfect for homelab boxes, refurb fleet machines, or cloud-style metal nodes.

## Components
- **dnsmasq (or equivalent)** - Provides proxy-DHCP responses pointing to the TFTP server and iPXE entrypoint.
- **TFTP/iPXE** - Hosts the short bootstrap program that loads the Talos kernel/initrd.
- **HTTP artefact server** - Serves Talos squashfs images, machine configurations, and the ignition-style boot scripts.
- **Talos machine configs** - Generated with `talosctl gen config` and stored declaratively so updates can be applied repeatably.

From here, the deeper dives cover DNS/TFTP plumbing, firmware requirements, and the exact iPXE/Talos hand-off.
