---
title: Serving Talos via PXE
slug: guides/netbooting-x86/serving-talos-via-pxe
description: Delivering immutable nodes on demand
draft: true
---

The x86 machines boot Talos straight from the Pi cluster, with nothing to configure per machine. Network-boot one and it lands in Omni, already trusting the lab CA. The same boot menu can wipe a machine and start it over, which is what replaced the USB stick.

## Explanation

The hard part was never the PXE boot itself, it was trust. Omni sits behind the lab's self-signed CA, and a Talos machine has to trust that CA before it can dial SideroLink. Getting the CA onto a machine for its first boot was easy enough, but Omni then installed Talos from a stock image, the CA was gone, and the machine dropped off. Config patches can't fix that, because they only reach a machine once it has registered.

So the CA goes into the image. The [Image Factory](https://github.com/siderolabs/image-factory) builds Talos images from a *schematic*, and a schematic can embed machine config. Ours embeds two things:

- a `TrustedRootsConfig` holding the lab CA
- Omni's join config (SideroLink, event sink and log documents)

Omni 1.13 builds each machine's installer from the schematic it booted with, so the CA is there from the first boot through install, reboots and upgrades. No Let's Encrypt, nothing that needs the internet to vouch for us.

## Implementation

Everything lives in the `ainur` cluster:

| Piece | File |
|-------|------|
| Builds the schematic, writes `boot.ipxe` | `src/manifests/ainur/sidero-omni/talos-schematic-job.yaml` |
| Proxy DHCP, x86 UEFI clients only | `src/manifests/ainur/pi-netboot/proxy-dhcp.yaml` |
| `ipxe.efi` over TFTP | `src/manifests/ainur/pi-netboot/tftp-deployment.yaml` |
| `boot.ipxe` over HTTP | `src/manifests/ainur/pi-netboot/http-deployment.yaml` |
| The same image as a USB ISO | `src/manifests/ainur/pi-netboot/talos-iso.yaml` |

### 1. The schematic

Once Omni is up, the Job asks it for the join config (`omnictl jointoken machine-config`), puts the lab CA in front of it, and posts the result to the factory:

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
      - siderolabs/iscsi-tools        # Longhorn
      - siderolabs/util-linux-tools   # Longhorn
  embeddedMachineConfiguration: |
    apiVersion: v1alpha1
    kind: TrustedRootsConfig
    name: lab-root-ca
    certificates: |
      -----BEGIN CERTIFICATE-----
      ...
    ---
    apiVersion: v1alpha1
    kind: SideroLinkConfig
    ...
```

The factory answers with the schematic's ID, a hash of its content, so a new lab CA or join token simply gives a new ID, a new `boot.ipxe` and a new ISO.

### 2. The boot chain

The router keeps handing out addresses. The proxy DHCP only adds a boot answer, and only for x86 UEFI PXE clients (`--pxe-service=...,x86-64_EFI,...`), so the Pis, which find TFTP from their EEPROM through DHCP option 66, are unaffected. Both run happily side by side.

```
firmware PXE  ->  ipxe.efi over TFTP from the VIP, 192.168.1.59
iPXE          ->  http://192.168.1.59/talos/boot.ipxe
boot.ipxe     ->  a menu, then the Talos kernel and initramfs from pxe.factory.talos.dev
```

`ipxe.efi` comes from the `quay.io/poseidon/dnsmasq` image, which is iPXE 2.0 with HTTPS built in: the factory only serves HTTPS.

### 3. The menu

`boot.ipxe` is a two-entry menu:

```
#!ipxe
menu Talos
item talos Talos
item reset Talos (Reset system disk: wipes it, then joins Omni)
choose --default talos --timeout 10000 target || goto talos
goto ${target}
:talos
chain --replace --autofree https://pxe.factory.talos.dev/pxe/<schematic>/v1.14.5/metal-${buildarch}
:reset
kernel https://pxe.factory.talos.dev/image/<schematic>/v1.14.5/kernel-amd64 <the factory's arguments> talos.experimental.wipe=system
initrd https://pxe.factory.talos.dev/image/<schematic>/v1.14.5/initramfs-amd64.xz
boot
```

- **Talos**, the default after ten seconds, boots the image as it is.
- **Reset system disk** is the network version of the ISO's entry of the same name: the same kernel with `talos.experimental.wipe=system`, which wipes the whole system disk before anything else runs. It's for a machine Omni can't reach any more (see [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/)). It's never the default, and the argument is only on iPXE's kernel line, not in the schematic, so it can't follow the machine into its install and wipe it on every boot.

### 4. Into Omni

The machine boots in maintenance mode, dials SideroLink with the CA it already trusts, and registers. The cluster template allocates it to `talos-default`, Omni installs Talos from the same schematic onto the NVMe, and after the reboot it boots from the NVMe and reconnects on its own. Once the cluster is up, a Job installs Argo CD on it and points it at `src/manifests/arda`.

## Going offline

For now the images come from the public factory. To cut that cord, run a self-hosted Image Factory (it has its own Helm chart, `siderolabs/image-factory:deploy/helm/image-factory`), then point `registries.factories` in Omni's values and the URLs in the schematic Job at it.

## Troubleshooting

- **No boot offer?** `kubectl -n ainur-netboot logs deploy/proxy-dhcp` shows every PXE request it sees, with the client's MAC and `PXEClient:Arch:00007` for x86 UEFI. Nothing there means the machine isn't asking over UEFI: see [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/).
- **TFTP `File not found` for `ipxe.efi`?** The TFTP pod copies it into the boot volume when it starts, and the Pi image builder's `--delete` syncs skip it. Restarting the TFTP DaemonSet puts it back: `kubectl -n ainur-netboot rollout restart ds/tftp`.
- **Back at the disk's boot menu after the downloads started?** iPXE gave up partway through (the initramfs is about 115 MB, over HTTPS from the factory) and the firmware moved on to the next boot entry. The first attempt on the first ProDesk did this and the second went through, so boot it again and watch for an error with an `https://ipxe.org/...` code.
- **iPXE starts but finds no script?** `curl http://192.168.1.59/talos/boot.ipxe`. If it's missing, check `kubectl -n ainur-sidero-omni logs job/talos-schematic`.
- **Machine never shows up in Omni?** Its console prints the SideroLink connection attempts. `certificate signed by unknown authority ... "Lab Root CA"` means it's running an image made for a different lab CA: an install from before ainur was rebuilt, or a stale schematic. Network-boot it and pick **Reset system disk**.

## Next Steps

Continue with [Bootstrapping Arda](/project-iluvatar/getting-started/bootstrap-arda/) for the whole bring-up, or [Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/) for putting a machine back in.
