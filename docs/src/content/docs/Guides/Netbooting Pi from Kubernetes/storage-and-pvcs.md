---
title: Storage & PVCs
slug: guides/netbooting-pi-from-kubernetes/storage-and-pvcs
description: The six Longhorn RWX volumes the netboot stack uses, why they're RWX, and which pod reads which.
sidebar:
  order: 2
draft: false
---

The whole stack runs as DaemonSets on hostNetwork, so any node might end up serving boot files at any moment. That means every PVC the stack uses has to be `ReadWriteMany` — otherwise a kube-vip flap could land the VIP on a node that can't actually mount the storage.

## Explanation

There are six volumes, and they fall into two categories:

- **Things Pis read at boot.** Boot files (TFTP/HTTP) and the OS root (NFS). These are read by every TFTP/NFS/HTTP pod, simultaneously, on every node. So: RWX.
- **Builder scratch space.** Download, extracted, output. Only one builder Job runs at a time, but the volumes outlive it so re-runs are fast (no re-downloading).

Longhorn does RWX via an NFS frontend (Longhorn spins up its own NFS server pod per RWX volume). Cost: a slight bit of indirection compared to RWO. Benefit: pods on any node can mount the same data without fuss.

All six PVCs use `storageClassName: longhorn-replicated-ext4-immediate`:

- `longhorn-replicated-…` — Longhorn-managed, replicated across nodes.
- `…-ext4-…` — formatted ext4 because XFS has a minimum filesystem size that some of these PVCs are below.
- `…-immediate` — the binding mode. `Immediate` means Longhorn provisions the volume as soon as the PVC is created, instead of waiting for a pod to schedule. For DaemonSets this matters because there's no single "pod has scheduled" moment to wait for.

## Implementation

```yaml
# src/manifests/ainur/pi-netboot/pvcs.yaml (excerpt)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pi-netboot-boot
  labels:
    ainur.kidd.network/workload: pi-netboot
    ainur.kidd.network/volume: boot
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: longhorn-replicated-ext4-immediate
  resources:
    requests:
      storage: 128Mi
```

The six volumes in full:

| PVC | Size | Read by | Written by |
|-----|------|---------|------------|
| `pi-netboot-boot` | 128Mi | TFTP, HTTP | Builder |
| `pi-netboot-os` | 5Gi | NFS | Builder |
| `pi-netboot-nfs-state` | 1Gi | NFS (rpc state) | NFS itself |
| `pi-netboot-download` | 2Gi | Builder (image cache) | Builder |
| `pi-netboot-extracted` | 5Gi | Builder | Builder |
| `pi-netboot-output` | 2Gi | Builder | Builder |

### Why split into so many

The temptation was to use one big PVC and split by directory. I chose six because:

- **Different lifetimes.** Boot/OS volumes are "live data" you don't want to nuke. Download/extracted/output are caches — there are `CLEAN_*_FILES` env vars in the [builder Job](../../../../../../src/manifests/ainur/pi-netboot/builder-job.yaml) that wipe them between runs.
- **Different sizes.** A 128Mi boot partition next to a 5Gi OS share next to a 2Gi cache — over-provisioning one to accommodate the others would waste replicated storage.
- **Clarity.** Looking at `kubectl get pvc -n ainur-netboot` and seeing what's what is faster than parsing one big PVC's directory structure.

### Labels

Every PVC has `ainur.kidd.network/workload: pi-netboot` plus a `ainur.kidd.network/volume: <role>` label. Not strictly necessary but useful for selecting all the storage for this workload in one query:

```bash
kubectl -n ainur-netboot get pvc -l ainur.kidd.network/workload=pi-netboot
```

If I ever need to migrate the stack between StorageClasses I'd lean on these labels for the dance.

## What you should see after this lands

```text
$ kubectl -n ainur-netboot get pvc
NAME                    STATUS   VOLUME       CAPACITY  ACCESS MODES   STORAGECLASS
pi-netboot-boot         Bound    pvc-…        128Mi     RWX            longhorn-replicated-ext4-immediate
pi-netboot-download     Bound    pvc-…        2Gi       RWX            longhorn-replicated-ext4-immediate
pi-netboot-extracted    Bound    pvc-…        5Gi       RWX            longhorn-replicated-ext4-immediate
pi-netboot-nfs-state    Bound    pvc-…        1Gi       RWX            longhorn-replicated-ext4-immediate
pi-netboot-os           Bound    pvc-…        5Gi       RWX            longhorn-replicated-ext4-immediate
pi-netboot-output       Bound    pvc-…        2Gi       RWX            longhorn-replicated-ext4-immediate
```

If any PVC is stuck `Pending`, it's almost always Longhorn finding its feet — `kubectl -n longhorn-system get pods` and check the engine images are healthy.

## Next Steps

[The VIP with kube-vip →](./the-vip-with-kube-vip/) — how a single stable IP gets advertised across the cluster.
