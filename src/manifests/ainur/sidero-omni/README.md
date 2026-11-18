# sidero-omni

Sidero Omni deployment for the x86 / Talos side of project-iluvatar.

This directory is the in-repo source path for the [`sidero-omni` Argo CD Application](../sidero-omni.yml). It bundles the v2 Omni Helm chart from `siderolabs/omni @ v1.13.3` with the project-specific values, the GPG key bootstrap for etcd encryption, the cluster template that defines what x86 Talos machines look like once they join, and the Talos image those machines boot.

## What lives here

| File | Role |
|------|------|
| `values.yaml` | Helm values for the upstream `siderolabs/omni` v2 chart. Includes a multi-SAN `Certificate` for the three Omni hostnames as an `extraObjects` entry. |
| `gpg-generator.yaml` | One-shot `Job` that generates a GPG private key and stores it as the `omni-gpg` Secret. The chart references this via `etcdEncryptionKey.existingSecret`. |
| `gpg-backup-pvc.yaml` | Small PVC where the GPG key gets backed up so re-running the generator doesn't lose it. |
| `omni-cluster-template-sync-job.yaml` | `Job` that runs `omnictl cluster template sync` after Omni is up, registering the cluster template defined below. |
| `omni-config/machine-class.yaml` | The `available` machine class: every x86 (amd64) machine that joins Omni. Applied by the sync Job before the template. |
| `omni-config/omni-cluster-template.yaml` | The Talos cluster template: one control plane, and every other machine as a worker (`size: unlimited`), so it starts with one machine and grows. Workloads run on the control plane too. Talos installs to the NVMe drive; the SATA SSD is Longhorn's. |
| `talos-schematic-job.yaml` | `Job` that builds the Talos image the x86 machines boot (lab CA + Omni join config embedded) and writes `boot.ipxe` and the ISO's address for `ainur-netboot`, whose `talos-iso` Job caches the ISO for USB. |
| `arda-bootstrap-job.yaml` | `Job` that installs Argo CD on the `talos-default` cluster once it is up, and points it at `src/manifests/arda`. |
| `arda-disks-cronjob.yaml` | `CronJob` that, every 10 minutes, wipes an arda machine's SATA SSD when Longhorn's volume isn't ready and the disk holds something else (old partitions), so Talos can create the volume, then labels the node for Longhorn once it is. Never touches a disk with a Talos user volume on it, or the system disk. |
| `unifi-cronjob.yaml` | `CronJob` that, every 5 minutes, keeps the UniFi router's side of the lab: each arda machine's DHCP reservation (from `.53`) and its hostname, `valinor-<last octet>`; `kidd.network` and `*.kidd.network` → ainur's VIP in local DNS; DHCP option 66 → ainur's VIP once ainur serves netboot (`rebootstrap.sh` points it at the VM while ainur is down); and a port forward per port of every arda Service annotated `kidd.network/port-forward: "true"`. Only touches forwards it made (named `k8s ...`). |

Both Jobs run `omnictl` as the `automation` service account, which Omni creates on its first start (`initialServiceAccount` in `values.yaml`) and whose key it writes to its own data volume. The Jobs mount that volume read-only, on Omni's node. Its key lasts a year, the most Omni allows; a cold rebuild makes a new one.

The etcd encryption key from `gpg-generator.yaml` is only that, and never expires. It used to double as an `omnictl` user key, which Omni only accepts after a browser login and caps at a few hours.

## Bootstrap flow

Argo CD reconciles this Application after the cert-manager and trust-manager stack is healthy (the chart is sync-wave `2`). The order of operations:

1. **Namespace `ainur-sidero-omni` is created** with `ainur.kidd.network/ca: inject` (via `managedNamespaceMetadata` on the Argo CD Application).
2. **trust-manager** publishes the `lab-ca` ConfigMap into the namespace (consumed by `extraVolumes` in `values.yaml` and mounted into the Omni pod as the system CA bundle).
3. **GPG generator Job** (sync-wave `-2`) runs, creates the `omni-gpg` Secret.
4. **`omni` multi-SAN Certificate** is materialised by cert-manager into `omni-tls` (covers `omni.kidd.network`, `omni.kubernetes.kidd.network`, `omni.siderolink.kidd.network`).
5. **Omni Helm chart** deploys: one pod, three Ingresses sharing `omni-tls`, three Services (main h2c, k8s-proxy https, wireguard UDP NodePort).
6. **Cluster-template sync Job** applies the machine class and runs `omnictl cluster template sync` against the running Omni, substituting `${LAB_ROOT_CA_INDENTED}` with the contents of the lab CA before applying.
7. **Talos schematic Job** registers a schematic with the Image Factory and points `http://192.168.1.59/talos/boot.ipxe` at it. `ainur-netboot`'s `talos-iso` CronJob checks every 5 minutes and caches the same image as `http://bootstrap.kidd.network/talos-media/metal-amd64.iso`.
8. Omni is ready to receive Talos machines: power one on, from the network or a USB stick, and it boots straight into Omni, which allocates it to `talos-default`.
9. **arda bootstrap Job** retries until `talos-default` is up, then installs Argo CD there with an `arda` root app for `src/manifests/arda`.

## How the machines trust the lab CA

This was the blocker on Omni v1.7.2: a machine could be made to trust the lab CA on its first boot, but Omni then installed Talos from a stock image, and the machine lost the CA and its SideroLink connection. Config patches could not help, because they only arrive after the machine has registered.

The fix is to put the CA in the image itself. `talos-schematic-job.yaml` builds an [Image Factory](https://github.com/siderolabs/image-factory) schematic whose `embeddedMachineConfiguration` holds:

- a `TrustedRootsConfig` with the lab CA, and
- the SideroLink, event sink and log documents from `omnictl jointoken machine-config`.

Since Omni 1.13, a machine's installer is built from the schematic it booted with, keeping every embedded document except the SideroLink ones Omni manages itself. So the CA is there from the first second of the first boot, and stays through install, reboots and upgrades.

The x86 boot path, from `ainur-netboot`:

```
firmware PXE --(proxy-dhcp.yaml)--> ipxe.efi over TFTP from 192.168.1.59
iPXE         --(proxy-dhcp.yaml)--> http://192.168.1.59/talos/boot.ipxe
boot.ipxe    --> https://pxe.factory.talos.dev/pxe/<schematic>/<version>/metal-amd64
```

Or from USB: write `http://bootstrap.kidd.network/talos-media/metal-amd64.iso` to a stick. It is the same schematic, so the CA and join config are in it too. Omni's own "download installation media" is not: it lacks the CA. A new lab CA or join token gives a new ISO, and the old stick stops working.

To go offline, run a self-hosted Image Factory (`siderolabs/image-factory:deploy/helm/image-factory`) and point both `registries.factories` in `values.yaml` and the URLs in `talos-schematic-job.yaml` at it.

## Verifying

```bash
# Pod, ingresses, certs healthy?
kubectl -n ainur-sidero-omni get pods,ingress,certificate

# Cluster template registered, schematic built?
kubectl -n ainur-sidero-omni logs job/omni-cluster-template-sync | tail -20
kubectl -n ainur-sidero-omni logs job/talos-schematic | tail -5
curl -s http://192.168.1.59/talos/boot.ipxe
curl -sI http://bootstrap.kidd.network/talos-media/metal-amd64.iso

# x86 machine asking for a boot file?
kubectl -n ainur-netboot logs deploy/proxy-dhcp
```

Once a machine has joined and rebooted, it should still be connected in Omni. Its config should carry the CA:

```bash
omnictl get machines
omnictl get clustermachineconfig <machine-id> -o yaml | grep -c TrustedRootsConfig
```

## Files removed in the v1 → v2 migration

For reference (visible in git history):

- `ingress.yaml` — custom Service + Traefik IngressRoutes; replaced by chart's built-in `ingress.main` and `ingress.kubernetesProxy`.
- `siderolink-ingressroute.yaml` — custom h2c-backend IngressRoute for the siderolink endpoint; replaced by chart's `ingress.siderolinkApi`.
- `omni-servers-transport.yaml` — Traefik `ServersTransport` for verifying the Omni pod's self-served HTTPS cert; not needed in v2 because the backend is now h2c (cleartext, no backend TLS).
- `omni-certificate.yaml` — manual multi-SAN Certificate; now declared inside `values.yaml` as an `extraObjects` entry so it lives next to the ingresses that consume it.
- `pvc.yaml` — manual PVC for Omni's data dir; the chart auto-creates one via `persistence.enabled: true`.
