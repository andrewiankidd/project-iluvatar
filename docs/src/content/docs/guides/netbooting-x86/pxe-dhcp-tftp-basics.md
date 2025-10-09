---
title: PXE / DHCP / TFTP Basics
description: Wiring Talos into the broadcast storm
---

This walkthrough explains how to advertise PXE services to x86 hardware without replacing your existing router or DHCP server.

## Explanation

Classic PXE on x86 expects three moving pieces:

1. **DHCP** assigns an IP address and optionally tells the firmware where to find boot files.
2. **TFTP** serves a tiny program (historically a PXE NBP, in our case iPXE) that knows how to fetch the real operating system kernel.
3. **HTTP/HTTPS** serves larger artifacts such as the Talos kernel, initramfs, and squashfs root.

Instead of taking over DHCP entirely, you can run dnsmasq in *proxy* mode. Your router still hands out leases, but dnsmasq listens to the same broadcast and replies with just the extra PXE options (66/67) pointing to the TFTP service. The end result: you keep your existing network stack, yet every PXE-capable box discovers the Talos bootstrap files.

## Implementation

### 1. Deploy dnsmasq in proxy mode

Here’s an example snippet suitable for either a bare-metal install or a containerised deployment:

```ini
# listen on the bootstrap VLAN only
interface=eth0

# proxy-DHCP range (no actual leases handed out)
dhcp-range=192.168.0.0,proxy

# TFTP/iPXE location
dhcp-option=66,192.168.0.66
dhcp-boot=undionly.kpxe,bootstrap-tftp,192.168.0.66
# Tell iPXE which script to chain once loaded
dhcp-option=option:bootfile-name,undionly.kpxe
dhcp-option=option:ipxe.configurl,http://192.168.0.66:8080/talos/talos.ipxe

# Optional: point Talos nodes at internal DNS
dhcp-option=6,192.168.0.3
```

- `dhcp-range ... proxy` tells dnsmasq to respond **without** serving addresses.
- `dhcp-option=66` is the TFTP server address.
- `dhcp-boot` names the iPXE binary that chainloads the Talos boot script.

Keep this file in version control with the rest of your bootstrap resources so that changes (new VLANs, different TFTP IP, etc.) are reviewed and documented.

### 2. Expose TFTP from the bootstrap stack

The example repository in this project ships a docker-compose stack with a TFTP container (`pghalliday/tftp`). Once running, it can serve:

- `undionly.kpxe` (for BIOS/Legacy clients)
- `ipxe.efi` (for UEFI firmware)
- `talos.ipxe` (chainloaded script that grabs kernels/initramfs over HTTP)

If you’re running the stack on Kubernetes, mount the same directory into `/var/tftpboot` using a hostPath or RWX volume.

### 3. Verify with a DHCP broadcast

From any Linux box on the management network:

```bash
sudo nmap --script broadcast-dhcp-discover | grep -E 'TFTP|PXE|Boot'
```

You should see output similar to:

```
|     TFTP Server Name: 192.168.0.66
|     Boot File Name: undionly.kpxe
```

At this point x86 firmware should pick up the bootstrap environment the same way the Pis do—only the hand-off script differs.

## Next Steps

With proxy DHCP and TFTP answering correctly, the next hurdle is making sure each x86 node actually *boots* the media you want. That means aligning firmware expectations (UEFI vs legacy) and pointing Talos at the right machine configs. Continue with [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).
