---
title: Netbooting x86
slug: guides/netbooting-x86
description: Talos over the wire
draft: true
---

arda's x86 machines boot Talos from ainur over the network: no USB stick, no per-machine config. Network-boot a machine once and it lands in Omni, trusting the lab CA, and Omni installs Talos to its NVMe. The same boot menu can also wipe a machine and start it over.

<details>
    <summary>What is PXE?</summary>

> PXE stands for "Preboot Execution Environment." It is a standard that allows a computer to boot and run an operating system over a network, without the need for a local storage device like a hard drive or a USB drive.
>
> PXE is commonly used in enterprise environments, data centers, and for large-scale deployment of operating systems. It enables network booting by providing a set of protocols and services that allow a computer to request and receive an operating system image from a server over the network.
>
>  -- ChatGPT 🤖
</details>

## How it fits together

It reuses the servers that netboot the Pis ([Diskless Pi Netboot](/project-iluvatar/guides/netbooting-raspberry-pi/)), all on ainur behind its VIP, `192.168.1.59`:

1. The machine's firmware asks for a network boot. The router gives it an address; ainur's **proxy DHCP** adds where to boot from.
2. It fetches **`ipxe.efi`** by TFTP from the VIP.
3. iPXE fetches **`boot.ipxe`** over HTTP from the VIP: a menu, defaulting to Talos.
4. Talos's kernel and initramfs come from the **Image Factory**, built from a schematic with the lab CA and Omni's join config inside.
5. Talos boots in maintenance mode, joins **Omni**, and Omni installs it to the NVMe.

| Page | What it covers |
|------|----------------|
| [PXE / DHCP / TFTP Basics](/project-iluvatar/guides/netbooting-x86/pxe-dhcp-tftp-basics/) | The proxy DHCP, and why it doesn't disturb the Pis |
| [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/) | The firmware settings that make a machine ask |
| [Serving Talos via PXE](/project-iluvatar/guides/netbooting-x86/serving-talos-via-pxe/) | The schematic, the menu and its **Reset system disk** entry |

## Network boot or USB

Network boot is the default. The same image is also offered as an ISO, for a machine that can't network-boot: `http://bootstrap.example.com/talos-media/metal-amd64.iso`, refreshed by ainur whenever the schematic changes. Both carry the same lab CA and join config, and both have a **Reset system disk** entry. See [Bootstrapping Arda](/project-iluvatar/getting-started/bootstrap-arda/).
