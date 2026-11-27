---
title: Storage & PVCs
slug: guides/netbooting-pi-from-kubernetes/storage-and-pvcs
description: The six local-path volumes the netboot stack uses, why they're on one node, and which pod reads which.
sidebar:
  order: 2
draft: false
---

The stack's volumes are k3s's local-path volumes on valar-50's NVMe, and everything that reads them (TFTP, NFS, HTTP, the builder) and the VIP are pinned to valar-50 with `nodeSelector: kidd.network/role: control-plane`. The VIP and the files are always on the same node.

## Explanation

There are six volumes, and they fall into two categories:

- **Things Pis read at boot.** Boot files (TFTP/HTTP) and the OS root (NFS).
- **Builder scratch space.** Download, extracted, output. Only one builder Job runs at a time, but the volumes outlive it so re-runs are fast (no re-downloading).

### Why not replicated storage

This started as six Longhorn `ReadWriteMany` volumes, so the servers could run on every Pi and the VIP could land on any of them. It worked, but cost more than it gave:

- Longhorn's own pods (manager, engine, CSI, an NFS server per RWX volume) and their 2 GB of images ran on every Pi, and the netbooted Pis keep images in RAM. Theirs filled, and nothing new could pull.
- The failover it bought was partial. ainur has one k3s server, on valar-50: when valar-50 is down the cluster is too, wherever the boot files are.

So the volumes went where the server is. `local-path` is k3s's built-in provisioner, a directory per volume under `/var/mnt/nvme/local-path` (set by the k3s server's `--default-local-storage-path`). Its binding mode is `WaitForFirstConsumer`, and with every consumer pinned to valar-50 that's where each volume is made. A volume's size is a request, not a limit: they share the NVMe.

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
    - ReadWriteOnce
  storageClassName: local-path
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
pi-netboot-boot         Bound    pvc-…        128Mi     RWO            local-path
pi-netboot-download     Bound    pvc-…        2Gi       RWO            local-path
pi-netboot-extracted    Bound    pvc-…        5Gi       RWO            local-path
pi-netboot-nfs-state    Bound    pvc-…        1Gi       RWO            local-path
pi-netboot-os           Bound    pvc-…        5Gi       RWO            local-path
pi-netboot-output       Bound    pvc-…        2Gi       RWO            local-path
```

A PVC stays `Pending` until a pod using it is scheduled (`WaitForFirstConsumer`); if one stays `Pending` after that, check valar-50 has `/var/mnt/nvme` mounted (`systemctl status nvme-prepare`).

## Next Steps

[The VIP with kube-vip →](./the-vip-with-kube-vip/) — how a single stable IP gets advertised across the cluster.
