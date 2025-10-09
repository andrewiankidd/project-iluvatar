---
title: x86 Software
description: Services layered on the Talos workload cluster
draft: true
---

### OS: Talos Linux
The main cluster netboots Talos Linux volumes provided by the Pis. Nodes stay immutable and ephemeral—pull the power or reprovision hardware and Talos simply rehydrates from Git-defined state. There’s no SSH shell, no local storage to manage, and every change flows through declarative manifests.

### Kubernetes (k8s)
Talos ships a vanilla, upstream-compatible Kubernetes control plane. Once a node joins, the kubelet comes online automatically, Argo CD syncs workloads, and Longhorn attaches storage, all without manual tinkering. It’s the same Kubernetes ecosystem I use elsewhere, just delivered in a sealed, API-first package.

### Longhorn
Longhorn provides distributed block storage, replication, and snapshots on top of Talos-managed nodes. It’s the glue that keeps PVCs alive when hardware moves around or nodes reboot during upgrades.

### Headlamp
Headlamp is the cluster dashboard: simple, lightweight, and compatible with Talos. It gives me a quick view into workloads without betraying the “no SSH” principle that Talos enforces.



## Quendi (Critical Workloads)

### ArgoCD

### LongHorn

### Istio/Traefik

### Cloudflared

## Atani (Regular Workloads)

### Jellyfin

### paperless

### Bitwarden

### etc

## Perian (Other Workloads)

### Mineserve

### etc
