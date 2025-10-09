---
title: Overview
description: Design goals
draft: true
---

Project Ilúvatar is a GitOps-driven homelab built around a Raspberry Pi bootstrap plane and a Talos-powered x86 workload cluster sharing the same network fabric. Every node PXE boots from the Pis, self-provisions, and joins the right layer without manual steps.

- Git stays the single source of truth; Argo CD reconciles both infrastructure and apps automatically.
- The bootstrap Pis host TFTP/HTTP, DNS, and Git services so new hardware can netboot and configure itself.
- Talos Linux, Longhorn, and supporting tooling keep the main cluster immutable while still providing reliable storage and backups.

### Hardware Priorities

I want the machines running in the cluster to:
 - Be compact
 - Be rack mountable
 - Support SSD storage (NVMe)
 - Support Power over Ethernet (PoE)

This lets me add bootstrap nodes by sliding them into the rack, hitting the switch, and watching PXE do its thing.
