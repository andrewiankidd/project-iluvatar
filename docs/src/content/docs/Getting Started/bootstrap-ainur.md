---
title: 🍓Bootstrap Ainur (ARM / Pi Cluster)
slug: getting-started/bootstrap-ainur
description: A fun, high‑level walkthrough of netbooting two Pis into a tiny, self‑managing Kubernetes cluster with SSO, GitOps, and mirrored storage.
sidebar:
  order: 2
draft: true
---

> tl;dr - I built a tiny, self‑managing private cloud on a Raspberry Pi (or a few tiny nodes): apps deploy themselves from Git, logins use single sign‑on, storage is mirrored, and it all boots over the network with no SD cards.

![TODO – hero screenshot placeholder](../../../assets/todo.png)

## What I Set Out To Build

- Raspberry Pi(s) booting over the network (no SD cards).
- k3s for a lightweight Kubernetes control plane and workers.
- Argo CD to continuously sync what’s in Git to what runs on the cluster.
- Dex (OIDC) for single sign‑on that everything trusts.
- Headlamp for human‑friendly visibility into the cluster.
- Longhorn for replicated, node‑independent storage.
- Omni to manage and eventually PXE‑provision other machines.

This page is the story and the vibes. Deep details live in the guides so I can keep this readable. If you want the “how”, follow the links as you go.

## Learn Netboot (so the Pis don’t need SD cards)

I prepped TFTP, NFS, and an Ubuntu Server cloud‑init that brings up enough of a userspace to hand off to k3s. I also learned the hard way that DHCP proxy mode can be… opinionated.

- Guides: Netbooting Raspberry Pi - [Pi Prep](/project-iluvatar/guides/netbooting-raspberry-pi/pi-prep/), [Cloud‑Init](/project-iluvatar/guides/netbooting-raspberry-pi/ubuntuserver-cloudconfig/), [First Boot](/project-iluvatar/guides/netbooting-raspberry-pi/pi-boot/)

## First Boot + Argo CD (the “it lives!” moment)

I flashed the first Pi’s image, pointed it at netboot, and it came up into k3s. From there, Argo CD installed itself and the platform apps.

- Milestones (screenshots go here):
  - “Hello, k3s” node shows up in `kubectl get nodes` ✅
  - Argo CD UI becomes reachable ✅
  - Headlamp dashboard shows the control plane ✅
- Notes:
  - I label worker nodes with `kidd.network/role=worker` and let scheduling follow that.

See also: [Flashing Image & Cloud Config](#flashing-image-cloud-config), [First Boot](#first-boot), [k3s Setup](#k3s-setup)

## Add Another Node (for storage/scale)

When I added another node as a worker, I used nodeSelectors to keep noisy stuff on workers and keep the control plane lean:

- Global nodeSelector points manager/UI workloads to workers.
- Longhorn:
  - system‑managed components (engine‑image, instance‑manager) only on workers.
  - CSI node plugin runs on all nodes so volumes can mount anywhere.

This gives a quiet control plane and lets the workers do the heavy lifting.

## Reality of Ephemeral tmpfs

Netboot is awesome, but RAM disks are not bottomless.

- Container images pile up fast; if the control plane used tmpfs for k3s data, I saw containerd run out of space.
- Fixes that worked:
  - Move k3s `data-dir` to real disk on the control plane, keep `/var/log` small tmpfs.
  - Pin image tags (no `latest`) and use `IfNotPresent` so we don’t re‑pull constantly.
  - Keep heavy DaemonSets off the control plane.

Guide: [Cluster Ops & Footprint](/project-iluvatar/guides/declarative-cluster/1-k3s/)

## NVMe + Longhorn (persistent storage)

I added NVMe to the worker(s) and let Longhorn take over as the replicated datastore.

- StorageClasses: xfs for big volumes, ext4 for tiny (XFS has a practical minimum).
- Reclaim policy: `Delete` so stale PVCs don’t leave orphaned volumes.
- Auto‑rebalance: `best‑effort` so replicas spread across both workers.

Guide: [Longhorn Setup](/project-iluvatar/guides/declarative-cluster/longhorn/)

## SSO + Ingress (nice URLs, one login)

Dex provides OIDC. Each app (Headlamp, Argo, Omni) is a client with an explicit callback URL. Ingress is Traefik with cert‑manager issuing certs from a local CA bundle that I inject where needed.

- Example hosts: `headlamp.kidd.network`, `argocd.kidd.network`, `omni.kidd.network`.
- Trust: a trust‑manager Bundle publishes a `lab-ca` ConfigMap the apps mount.

Guides: [Dex/SSO](/project-iluvatar/guides/declarative-cluster/dex/), [Ingress & TLS](/project-iluvatar/guides/declarative-cluster/ingress/)

## Omni (manage other machines)

Omni runs in‑cluster. It now accepts Dex OIDC and serves a friendly UI for adding machines. Next up for me is PXE‑provisioning x86 boxes with Talos via Omni.

- Ingress: `omni.kidd.network`
- If you see x509 issues, mount your lab CA onto `/etc/ssl/certs/ca‑certificates.crt` in Omni.

Guide: [Omni Basics](/project-iluvatar/guides/omni/)

## Caveats & “I Learned This The Spicy Way”

- DHCP proxy mode can be finicky; fall back to router `next-server` or a small provisioning VLAN if needed.
- Unique node identity matters. `--with-node-id` saves you from name collisions.
- Netboot + tmpfs is great for stateless nodes; move k3s data off tmpfs on the control plane.

## What’s Next

- Cut the tether completely: have the Pi control plane self‑host TFTP/NFS and act as PXE proxy.
- Omni + Talos PXE for x86 workers.
- Add observability (Loki/Grafana) and backups (Velero / Longhorn backup target).

![TODO – milestone collage placeholder](../../../assets/todo.png)

## Flashing Image & Cloud Config

![TODO](../../../assets/todo.png)

### TODO: still a WIP

> See also: [Cloud-Init](/project-iluvatar/guides/netbooting-raspberry-pi/5-ubuntuserver-cloudconfig/)

## First Boot

![TODO](../../../assets/todo.png)

### TODO: still a WIP

> See also: [Booting For The First Time](/project-iluvatar/guides/netbooting-raspberry-pi/4-pi-boot/)

## K3s Setup

![TODO](../../../assets/todo.png)

### TODO: still a WIP

> See also: [K3S](/project-iluvatar/guides/declarative-cluster/1-k3s/)
