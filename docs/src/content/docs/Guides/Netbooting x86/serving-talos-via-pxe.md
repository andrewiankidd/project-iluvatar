---
title: Serving Talos via PXE
slug: guides/netbooting-x86/serving-talos-via-pxe
description: Delivering immutable nodes on demand
draft: false
---

The x86 machines boot Talos straight from the Pi cluster, with nothing on their disks and nothing to configure per machine. Power one on and it lands in Omni, already trusting the lab CA.

## Explanation

The hard part was never the PXE boot itself, it was trust. Omni sits behind the lab's self-signed CA, and a Talos machine has to trust that CA before it can dial SideroLink. Getting the CA onto a machine for its first boot was easy enough, but Omni then installed Talos from a stock image, the CA was gone, and the machine dropped off. Config patches can't fix that, because they only reach a machine once it has registered.

So the CA goes into the image. The [Image Factory](https://github.com/siderolabs/image-factory) builds Talos images from a *schematic*, and a schematic can embed machine config. Ours embeds two things:

- a `TrustedRootsConfig` holding the lab CA
- Omni's join config (SideroLink, event sink and log documents)

Omni 1.13 builds each machine's installer from the schematic it booted with, so the CA is there from the first boot through install, reboots and upgrades. No Let's Encrypt, nothing that needs the internet to vouch for us.

That makes the lab CA part of every installed machine, so it has to outlive ainur. It comes from the bootstrap `.env` (`AINUR_LAB_CA_CRT`, `AINUR_LAB_CA_KEY`), and a rebuilt ainur uses the same one. Before that, each rebuild made a new CA, and every arda machine was left trusting one that no longer existed.

## Implementation

Everything lives in the `ainur` cluster:

| Piece | File |
|-------|------|
| Builds the schematic, writes `boot.ipxe` | `src/manifests/ainur/sidero-omni/talos-schematic-job.yaml` |
| Proxy DHCP, x86 UEFI clients only | `src/manifests/ainur/pi-netboot/proxy-dhcp.yaml` |
| `ipxe.efi` over TFTP | `src/manifests/ainur/pi-netboot/tftp-deployment.yaml` |
| `boot.ipxe` over HTTP | `src/manifests/ainur/pi-netboot/http-deployment.yaml` |

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

The factory answers with the schematic's ID, a hash of its content, so a new lab CA or join token simply gives a new ID.

### 2. The boot chain

```
firmware PXE  ->  ipxe.efi over TFTP from the VIP, 192.168.1.59
iPXE          ->  http://192.168.1.59/talos/boot.ipxe
boot.ipxe     ->  a menu: Talos, or Talos (Reset system disk)
```

![ainur's network boot menu](../../../../assets/docs/guides/netbooting-x86/ipxe-reset-menu.png)

- **Talos** (the default, after ten seconds) chains to `https://pxe.factory.talos.dev/pxe/<schematic>/v1.14.5/metal-${buildarch}`.
- **Talos (Reset system disk: wipes it, then joins Omni)** boots the same kernel with `talos.experimental.wipe=system` added, like the ISO's own reset entry. It wipes the whole system disk, including the `META` partition that marks it as installed, then carries on into maintenance mode and Omni. That's for a machine an earlier Omni installed, or one installed under another lab CA: neither can be reset over the network ([Re-bootstrapping Arda](/project-iluvatar/getting-started/rebootstrap-arda/)).

The wipe is an iPXE kernel argument, not part of the schematic. Omni builds the install from the schematic, so it can't carry the wipe into the installed system and wipe the disk on every boot. The Job fetches the factory's own iPXE script for the schematic, adds the argument to its `kernel` line, and checks it's there before publishing the menu.

### 3. Into Omni

The machine boots in maintenance mode, dials SideroLink with the CA it already trusts, and registers. The cluster template allocates it to `talos-default`, Omni installs Talos from the same schematic, and after the reboot it reconnects on its own. Once the cluster is up, a Job installs Argo CD on it and points it at `src/manifests/arda`.

The first machine becomes the control plane, every later one a worker. Both machine sets draw on the same machines, and Omni doesn't fill one before the other, so workers have their own machine class needing `kidd.network/arda-worker`. The `arda-disks` CronJob gives that label to a machine in no cluster only once the control plane has its machine.

## Going offline

For now the images come from the public factory. To cut that cord, run a self-hosted Image Factory (it has its own Helm chart, `siderolabs/image-factory:deploy/helm/image-factory`), then point `registries.factories` in Omni's values and the URLs in the schematic Job at it.

## Troubleshooting

- **No boot offer, or F9 has no network entry?** The firmware isn't doing UEFI network boot: [UEFI vs Legacy Boot](/project-iluvatar/guides/netbooting-x86/uefi-vs-legacy-boot/). `kubectl -n ainur-netboot logs deploy/proxy-dhcp` shows every PXE request it sees.
- **iPXE never starts, and the machine boots its disk?** TFTP answered `File not found` for `ipxe.efi`; its log says so. Restarting the `tftp` DaemonSet copies it back in.
- **iPXE starts but finds no script?** `curl http://192.168.1.59/talos/boot.ipxe`. If it's missing, check `kubectl -n ainur-sidero-omni logs job/talos-schematic`.
- **Machine never shows up in Omni?** Its console prints the SideroLink connection attempts. `certificate signed by unknown authority` means it's running something installed or built under another lab CA: reset it from the menu.
- **It registers, but Omni shows a config error on it?** A cluster template patch doesn't fit its role, such as deleting a control-plane taint from a worker. Role-specific patches go under `ControlPlane:` or `Workers:` in the template.

## Next Steps

Continue with [Bootstrapping Arda](/project-iluvatar/getting-started/bootstrap-arda/) for joining machines and checking the cluster, or move straight to [Deploy Core Workloads](/project-iluvatar/getting-started/deploy-core-workloads/).
