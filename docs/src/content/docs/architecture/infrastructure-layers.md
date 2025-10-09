---
title: Infrastructure Layers
description: Who runs what
draft: true
---

The naming theme leans on Tolkien: Ilúvatar creates the world, the Ainur shape it, and everyone else keeps the music going.

## Ilúvatar (Project)
The Git repository is the single source of truth for infrastructure, Talos/Kubernetes manifests, and bootstrap automation. Every environment derives from this definition.

## Eä (Environment / Network)
“The World That Is” covers physical racks, VLANs, DNS zones, DHCP, and the rest of the homelab plumbing that hosts both clusters.

## Ainur (Bootstrap Cluster)
A Raspberry Pi cluster providing dnsmasq, TFTP, HTTP artefact hosting, Git mirrors, and the Argo CD seed. Without the Ainur, nothing else comes online.

### Valar (Bootstrap Primary Nodes)
Primary Pis responsible for keeping PXE, Git, and Argo CD seed services available. They are the first stop for any new hardware joining the network.

### Maiar (Bootstrap Secondary Nodes)
Supporting Pis that add resilience, host auxiliary services, or soak up background tasks so the Valar can focus on bootstrap duties.

## Arda (Main Cluster)
The Talos-powered x86 fleet that actually runs workloads. Once Talos nodes join Arda, Kubernetes schedules everything from GitOps controllers to long-term services here.

### Valinor (Control Plane Nodes)
Talos control-plane machines maintaining etcd, the Kubernetes API server, and cluster-wide reconciliation loops.

### Istari (Worker Nodes)
General-purpose Talos workers that run application workloads, persistent storage, and the majority of day-to-day services.
