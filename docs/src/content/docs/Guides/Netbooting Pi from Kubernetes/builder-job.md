---
title: The Builder Job
slug: guides/netbooting-pi-from-kubernetes/builder-job
description: A one-shot Kubernetes Job that clones the repo, downloads the Ubuntu image, and stages boot/OS files into the PVCs.
sidebar:
  order: 4
draft: false
---

The PVCs from the previous page are empty until somebody puts files in them. That somebody is a `Job` that does pretty much exactly what the [original Pi-netboot guide](../../Netbooting%20Raspberry%20Pi/4-os-prep/) did on a host machine, but inside a privileged pod with the PVCs mounted instead of host directories.

## Explanation

The job has two phases, separated into an initContainer and a main container:

1. **`git-init` initContainer** — does a sparse, shallow clone of this repo and links the relevant scripts/assets into a shared `emptyDir`. The point of the sparse clone is to avoid pulling 100MB of unrelated history; we only need `bootstrap/netboot`.
2. **`builder` container** — runs the existing `bootstrap/netboot/scripts/*` against environment variables that point at the PVCs. Downloads `ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz`, extracts it, splits the boot and OS partitions, and writes them into the right PVCs.

It's a `Job` (not a `Deployment` or `CronJob`) because it's genuinely one-shot. If you want to refresh the image, re-apply the Job (it's idempotent on PVC content thanks to the `CLEAN_*_FILES` env vars) or just delete it and let kustomize recreate it.

## Implementation

### The Job

```yaml
# src/manifests/ainur/pi-netboot/builder-job.yaml (excerpt)
apiVersion: batch/v1
kind: Job
metadata:
  name: pi-netboot-builder
spec:
  backoffLimit: 0
  template:
    spec:
      initContainers:
        - name: git-init
          image: alpine:3.20
          command: ["sh","-c"]
          args:
            - |
              set -euo pipefail
              apk add --no-cache git ca-certificates
              update-ca-certificates || true
              git clone --depth=1 --filter=blob:none --sparse --branch main \
                https://github.com/andrewiankidd/project-iluvatar.git /mnt/netboot/repo
              git -C /mnt/netboot/repo sparse-checkout set bootstrap/netboot
              ln -sfn /mnt/netboot/repo/bootstrap/netboot/scripts /mnt/netboot/scripts
              ln -sfn /mnt/netboot/repo/bootstrap/netboot/assets /mnt/netboot/assets
          volumeMounts:
            - name: repo
              mountPath: /mnt/netboot
      containers:
        - name: builder
          image: andrewkidd/pi-netboot-builder:latest
          imagePullPolicy: Always
          securityContext:
            privileged: true
          env:
            - name: BOOTSTRAP_IP_ADDRESS
              value: 192.168.1.59
            - name: CLEAN_OS_FILES
              value: "false"
            - name: CLEAN_BOOT_FILES
              value: "false"
            # …
          envFrom:
            - configMapRef:
                name: pi-netboot-env
          volumeMounts:
            - { name: repo, mountPath: /mnt/netboot }
            - { name: boot, mountPath: /tmp/pi-netboot-builder/boot }
            - { name: os, mountPath: /tmp/pi-netboot-builder/os }
            - { name: download, mountPath: /tmp/pi-netboot-builder/download }
            - { name: extracted, mountPath: /tmp/pi-netboot-builder/extract }
            - { name: output, mountPath: /tmp/pi-netboot-builder/output }
            - { name: dev, mountPath: /dev }
      volumes:
        - name: repo
          emptyDir: {}
        - { name: boot, persistentVolumeClaim: { claimName: pi-netboot-boot } }
        - { name: os, persistentVolumeClaim: { claimName: pi-netboot-os } }
        # … and the others
        - name: dev
          hostPath: { path: /dev, type: Directory }
```

A few things worth a comment:

- **`backoffLimit: 0`** — if the build fails, don't retry forever. Investigate why it failed, fix it, re-apply.
- **`privileged: true` + hostPath `/dev`** — the builder uses loop devices to mount the image's partitions. Without `/dev` exposed and privileged mode the kernel won't let it.
- **`imagePullPolicy: Always`** on the builder — the `:latest` tag for `andrewkidd/pi-netboot-builder` rolls forward. I'd rather pin a version, but I haven't done it yet.
- **`envFrom: configMapRef: pi-netboot-env`** — see below.

### The ConfigMap that drives the build

```yaml
# src/manifests/ainur/pi-netboot/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pi-netboot-env
data:
  BOOTSTRAP_IP_ADDRESS: "SET_AUTOMATICALLY_VIA_HOSTIP"
  COMPOSE_PROFILE: "debian-netboot"
  ASSETS_DIR: "ubuntuserver"
  DOWNLOAD_LINK: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz"
```

- **`DOWNLOAD_LINK`** is the only thing you change to bump Ubuntu versions. Worth caching this on an internal mirror if you do it often.
- **`COMPOSE_PROFILE`** is a holdover from when the builder ran inside the original `docker-compose.yml` (see the [original guide](../../Netbooting%20Raspberry%20Pi/3-srv-prep/)). The builder image's scripts still respect the same profile selector.
- **`BOOTSTRAP_IP_ADDRESS: "SET_AUTOMATICALLY_VIA_HOSTIP"`** — this is misleading. The actual value `192.168.1.59` is set as an explicit `env:` entry on the Job (overriding the ConfigMap). The string in the ConfigMap is a remnant of an earlier attempt to derive it from the pod's host IP. There's a commented-out `valueFrom:` block in the Job spec hinting at the failed approach, with the comment "Hate that you cant do this via valueFrom".

### Why the sparse clone matters

The naive thing would be a vanilla `git clone https://...`. On this repo the full history is small *for now*, but as it grows that becomes wasteful for what is essentially a 30KB script directory.

`--depth=1 --filter=blob:none --sparse` is the three-clauses trick:

- `--depth=1` — only the latest commit.
- `--filter=blob:none` — don't fetch file blobs until you check them out.
- `--sparse` — set up sparse-checkout so we only ever materialise the paths we ask for.

Then `git sparse-checkout set bootstrap/netboot` materialises just that subtree. The clone is sub-second, even on a slow Pi network.

## What you should see after this lands

```text
$ kubectl -n ainur-netboot get job pi-netboot-builder
NAME                  COMPLETIONS   DURATION   AGE
pi-netboot-builder    1/1           4m12s      1h

$ kubectl -n ainur-netboot logs job/pi-netboot-builder | tail -20
[builder] Boot files written to /tmp/pi-netboot-builder/boot
[builder] OS files written to /tmp/pi-netboot-builder/os
[builder] Done.
```

The pod is `Completed` after, not `Running` — that's normal for a Job.

### Re-running

To rebuild (e.g. after bumping `DOWNLOAD_LINK`):

```bash
kubectl -n ainur-netboot delete job pi-netboot-builder
# Argo CD will recreate it on the next sync
```

If you have `CLEAN_OS_FILES` / `CLEAN_BOOT_FILES` set to `false` (the default), the build is incremental and will re-use the `download` and `extracted` volumes. Set them to `true` to force a full rebuild.

## Next Steps

[The TFTP DaemonSet →](./tftp-daemonset/) — the first place a Pi actually talks to the cluster.
