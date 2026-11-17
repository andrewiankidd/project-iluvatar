---
title: Serving Talos via PXE
slug: guides/netbooting-x86/serving-talos-via-pxe
description: Delivering immutable nodes on demand
draft: true
---

The x86 machines boot Talos straight from the Pi cluster, with nothing on their disks and nothing to configure per machine. Power one on and it lands in Omni, already trusting the lab CA.

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

The router keeps handing out addresses. The proxy DHCP only adds a boot answer, and only for x86 UEFI PXE clients, so the Pis (which find TFTP from their EEPROM) are unaffected.

```
firmware PXE  ->  ipxe.efi over TFTP from the VIP, 192.168.1.59
iPXE          ->  http://bootstrap.kidd.network/talos/boot.ipxe
boot.ipxe     ->  chain https://pxe.factory.talos.dev/pxe/<schematic>/v1.14.5/metal-${buildarch}
```

### 3. Into Omni

The machine boots in maintenance mode, dials SideroLink with the CA it already trusts, and registers. The cluster template allocates it to `talos-default`, Omni installs Talos from the same schematic, and after the reboot it reconnects on its own. Once the cluster is up, a Job installs Argo CD on it and points it at `src/manifests/arda`.

## Going offline

For now the images come from the public factory. To cut that cord, run a self-hosted Image Factory (it has its own Helm chart, `siderolabs/image-factory:deploy/helm/image-factory`), then point `registries.factories` in Omni's values and the URLs in the schematic Job at it.

## Troubleshooting

- **No boot offer?** `kubectl -n ainur-netboot logs deploy/proxy-dhcp` shows every PXE request it sees. Make sure the machine is set to UEFI network boot.
- **iPXE starts but finds no script?** `curl http://bootstrap.kidd.network/talos/boot.ipxe`. If it's missing, check `kubectl -n ainur-sidero-omni logs job/talos-schematic`.
- **Machine never shows up in Omni?** Its console prints the SideroLink connection attempts. A TLS error there means it booted an image without the CA, usually a stale schematic.

## Next Steps

Continue with [PXE Boot & Talos Install](/project-iluvatar/getting-started/bootstrap-arda/) for the high-level cluster bring-up, or move straight to [Deploy Core Workloads](/project-iluvatar/getting-started/deploy-core-workloads/).
