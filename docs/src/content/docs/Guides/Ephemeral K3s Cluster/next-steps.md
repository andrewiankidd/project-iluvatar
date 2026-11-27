---
title: 'Summary & Next Steps'
slug: guides/ephemeral-netboot-pi-cluster/next-steps
description: Quick recap of what you built and where to go next.
sidebar:
  order: 11
draft: false
---

Over this guide set you built a netboot flow that can run K3s from an ephemeral root, watched the k3s-bootstrap scripts pick roles and stage manifests, replaced the smoke-test app with a bootstrap HTTP endpoint for leader/token sharing, and trimmed the install to stay friendly to tmpfs. It’s a solid milestone that shows the ephemeral approach is workable and repeatable.

### Automation

The process is scripted and versioned (cloud-init, k3s-bootstrap, manifests) so you don’t have to redo steps by hand. Extend the same patterns when you add more nodes or components.

### Next Steps

- Add observability (e.g., Prometheus/Grafana) and enable TLS via cert-manager or Traefik ACME.
- Introduce persistence only where needed (e.g., Longhorn on NVMe, targeted NFS mounts) while keeping the root ephemeral.
- Evolve GitOps structure to separate cluster essentials from app payloads; keep manifests small.
- Exercise failure cases: reboot nodes to watch leader election, verify agents rejoin, and confirm manifests reapply cleanly.
