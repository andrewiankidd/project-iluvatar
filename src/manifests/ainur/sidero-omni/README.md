# sidero-omni

Sidero Omni deployment for the x86 / Talos side of project-iluvatar.

This directory is the in-repo source path for the [`sidero-omni` Argo CD Application](../sidero-omni.yml). It bundles the v2 Omni Helm chart from `siderolabs/omni @ v1.7.2` with the project-specific values, the GPG key bootstrap for etcd encryption, and the cluster template that defines what x86 Talos machines look like once they join.

## What lives here

| File | Role |
|------|------|
| `values.yaml` | Helm values for the upstream `siderolabs/omni` v2 chart. Includes a multi-SAN `Certificate` for the three Omni hostnames as an `extraObjects` entry. |
| `gpg-generator.yaml` | One-shot `Job` that generates a GPG private key and stores it as the `omni-gpg` Secret. The chart references this via `etcdEncryptionKey.existingSecret`. |
| `gpg-backup-pvc.yaml` | Small PVC where the GPG key gets backed up so re-running the generator doesn't lose it. |
| `omnictl-config-secret.yaml` | `omniconfig.yaml` for the `omnictl` CLI, identity `omni-sync@local`. Used by the cluster-template sync job. |
| `omni-cluster-template-sync-job.yaml` | `Job` that runs `omnictl cluster template sync` after Omni is up, registering the cluster template defined below. |
| `omni-config/omni-cluster-template.yaml` | The Talos cluster template: control plane + workers via `machineClass: available`, plus the **`TrustedRootsConfig` patch that adds the lab CA to every member machine's trust store**. |

## Bootstrap flow

Argo CD reconciles this Application after the cert-manager and trust-manager stack is healthy (the chart is sync-wave `2`). The order of operations:

1. **Namespace `ainur-sidero-omni` is created** with `ainur.kidd.network/ca: inject` (via `managedNamespaceMetadata` on the Argo CD Application).
2. **trust-manager** publishes the `lab-ca` ConfigMap into the namespace (consumed by `extraVolumes` in `values.yaml` and mounted into the Omni pod as the system CA bundle).
3. **GPG generator Job** (sync-wave `-2`) runs, creates the `omni-gpg` Secret.
4. **`omni` multi-SAN Certificate** is materialised by cert-manager into `omni-tls` (covers `omni.kidd.network`, `omni.kubernetes.kidd.network`, `omni.siderolink.kidd.network`).
5. **Omni Helm chart** deploys: one pod, three Ingresses sharing `omni-tls`, three Services (main h2c, k8s-proxy https, wireguard UDP NodePort).
6. **Cluster-template sync Job** runs `omnictl cluster template sync` against the running Omni, substituting `${LAB_ROOT_CA_INDENTED}` with the contents of the lab CA before applying.
7. Omni is ready to receive Talos machines.

## Verifying the install (smoke test before any Talos machines)

```bash
# Pod, ingresses, certs healthy?
kubectl -n ainur-sidero-omni get pods,ingress,certificate

# Web UI reachable, OIDC issuer correct?
curl -s https://omni.kidd.network/.well-known/openid-configuration | jq .

# Cluster template registered?
kubectl -n ainur-sidero-omni logs job/omni-cluster-template-sync | tail -20
```

You should see the Omni pod `Running`, three Ingresses with the `omni-tls` secret, the `omni` Certificate `Ready: True`, and the cluster-template sync job `Complete`.

## Verifying the TLS bootstrap problem is (or isn't) solved

After Omni is up, generate a Talos image, boot one x86 machine, let it auto-allocate to the `talos-default` cluster. **Before the machine reboots into runtime mode**, check whether the cluster-template patch is making it into the rendered ClusterMachineConfig:

```bash
# Get the machine ID from Omni
kubectl -n ainur-sidero-omni exec deploy/omni -- /omnictl get machines

# Inspect what Omni will push to that machine
kubectl -n ainur-sidero-omni exec deploy/omni -- \
  /omnictl get clustermachineconfig <machine-id> -o yaml \
  | yq 'select(.kind == "TrustedRootsConfig")'
```

**Two outcomes:**

- **TrustedRootsConfig is present** → the patch lands. If the machine still fails to reconnect after reboot, the bug is in Talos's boot-order (TrustedRootsConfig applied after siderolink dials) and the fallback is the [Image Factory schematic approach](../../../../BACKLOG.md#active-direction--talosomni-v2-chart-migration) (bake the CA into the Talos image's META partition at build time).
- **TrustedRootsConfig is absent** → the cluster-template patch isn't surviving the patcher. Reshape the patch from a single-mapping `inline:` to a literal block scalar form and re-test.

## What this chart deliberately does NOT do

- It does not inject the lab CA into machine join configs. Omni v2 has no such mechanism (confirmed against the v1.7.2 source). The trust establishment for `siderolink.api` happens via:
  - Kernel cmdline + image-time injection (first boot only)
  - Cluster-template `TrustedRootsConfig` patch (persists across reboots, hopefully)
- It does not host an Image Factory. If image-side trust baking becomes necessary, Image Factory has its own Helm chart at `siderolabs/image-factory:deploy/helm/image-factory` and can be deployed alongside.

## Files removed in the v1 → v2 migration

For reference (visible in git history):

- `ingress.yaml` — custom Service + Traefik IngressRoutes; replaced by chart's built-in `ingress.main` and `ingress.kubernetesProxy`.
- `siderolink-ingressroute.yaml` — custom h2c-backend IngressRoute for the siderolink endpoint; replaced by chart's `ingress.siderolinkApi`.
- `omni-servers-transport.yaml` — Traefik `ServersTransport` for verifying the Omni pod's self-served HTTPS cert; not needed in v2 because the backend is now h2c (cleartext, no backend TLS).
- `omni-certificate.yaml` — manual multi-SAN Certificate; now declared inside `values.yaml` as an `extraObjects` entry so it lives next to the ingresses that consume it.
- `pvc.yaml` — manual PVC for Omni's data dir; the chart auto-creates one via `persistence.enabled: true`.
