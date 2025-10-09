---
title: Naming & Conventions
description: Tolkien everywhere
draft: true
---

Ilúvatar sets the tone: every part of the platform borrows from Tolkien’s creation myth so that each name hints at its role.

### Core Realms
- **Ilúvatar** — the Git repository, single source of truth orchestrating everything.
- **Eä** — the wider homelab environment: LAN, DNS, VLANs, and supporting infra.
- **Arda** — the x86 Talos cluster where workloads actually run.
- **Ainur** — the Raspberry Pi bootstrap cluster hosting PXE, dnsmasq, Git mirrors, and the Argo CD seed.

### Nodes
- **Valar** — primary bootstrap Pis; if one fails, another Valar should step in.
- **Maiar** — helper Pis that keep services resilient but don’t carry the seed workloads.
- **Valinor** — Talos control-plane nodes.
- **Istari** — Talos worker nodes that execute the day-to-day workloads.

### Workloads
- **Quendi** — critical apps needed for the cluster to function (e.g. Argo CD, Longhorn).
- **Atani** — helpful but not life-or-death services (media, automation).
- **Perian** — experiments and hobby projects.
