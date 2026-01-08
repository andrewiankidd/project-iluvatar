---
title: Running Kubernetes in RAM
slug: guides/ephemeral-netboot-pi-cluster/k3s-in-ram
description: Cloud-init settings to keep a netbooted K3s node lean on tmpfs/low-disk roots.
sidebar:
  order: 3
draft: false
---

This guide covers explanation and implementation of the cloud-init pieces that let K3s run comfortably on low-disk or tmpfs-backed roots. The focus is on what user-data sets up to keep writes light and disposable.

## Explanation

The netbooted node lives mostly in RAM, so we trim anything that would otherwise fill a tiny root. Cloud-init rehomes logs to tmpfs, keeps bootstrap state in `/tmp` and `/run`, and installs a lean K3s server that only writes what it must. Manifests are staged once and copied over after K3s is ready, keeping churn low.

## Implementation

### Volatile journald
Start by making journald write to tmpfs right after boot so log files never hit disk.

```yaml
#cloud-config (snippet)
runcmd:
  - [ mkdir, -p, /run/log/journal ]
  - [ systemctl, restart, systemd-journald ]
```

### Bootstrap state stays in RAM
Tokens and extra args live in `/tmp/k3s` and `/run/k3s-bootstrap`, so you aren’t spraying secrets or temp files onto persistent storage.

```bash
# /usr/local/bin/k3s-20-install.sh (excerpt)
K3S_TOKEN="${K3S_TOKEN:-my-cluster-token}"
K3S_COMMON_ARGS="${K3S_COMMON_ARGS:-}"
K3S_SERVER_ARGS="${K3S_SERVER_ARGS:- --cluster-init --node-label=kidd.network/role=control-plane --token ${K3S_TOKEN}}"
ARGS_DIR="/run/k3s-bootstrap"
if [ -f "$ARGS_DIR/K3S_COMMON_ARGS" ]; then
  K3S_COMMON_ARGS="$K3S_COMMON_ARGS $(tr '\n' ' ' < "$ARGS_DIR/K3S_COMMON_ARGS")"
fi
if [ -f "$ARGS_DIR/K3S_SERVER_ARGS" ]; then
  K3S_SERVER_ARGS="$K3S_SERVER_ARGS $(tr '\n' ' ' < "$ARGS_DIR/K3S_SERVER_ARGS")"
fi
```

### Minimal server install
The installer uses only the flags it needs; anything extra can be layered in through the tmpfs arg files if you want to experiment without baking new images.

```bash
# /usr/local/bin/k3s-20-install.sh (excerpt)
INSTALL_K3S_VERSION="v1.33.6+k3s1"
K3S_ROLE="server"
curl -sfL https://get.k3s.io | \
  K3S_TOKEN="$K3S_TOKEN" \
  INSTALL_K3S_EXEC=" $K3S_COMMON_ARGS $K3S_SERVER_ARGS" \
  INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
  sh -s -
```

### One-shot manifest staging
Copy staged YAML once and be done with it. It’s enough to get essentials onto the node without creating ongoing writes.

```bash
# /usr/local/sbin/k3s-install-manifests.sh
src="/etc/k3s-manifests"
dst="/var/lib/rancher/k3s/server/manifests"
for f in "$src"/*.yaml "$src"/*.yml; do
  b=$(basename "$f")
  install -D -m0644 "$f" "$dst/$b"
done
```

```ini
# /etc/systemd/system/k3s-ready.path (excerpt)
[Path]
PathExists=/etc/rancher/k3s/k3s.yaml
PathExists=/var/lib/rancher/k3s/server/manifests
Unit=k3s-ready-dispatch.service
```

## Next Steps

- Keep `/etc/k3s-manifests` lean to minimize writes during boot.
- If you need persistent storage, mount it explicitly (e.g., NVMe for Longhorn) and leave the root ephemeral.
- Move to `deploying-k3s-on-netboot-nodes.md` to tie this into the full bootstrap flow.
