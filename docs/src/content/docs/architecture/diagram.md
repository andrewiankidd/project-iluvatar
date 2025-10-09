---
title:  Diagram
description: PXE data flow at a glance
draft: true
---
```
          +-----------------------+
          |     Dream Machine     |
          | (Router, VPN, DHCP)   |
          |  192.168.0.1/24       |
          +----------+------------+
                     |
                     | (SFP+ / Ethernet trunk)
                     v
          +-----------------------+
          |   24-Port PoE Switch  |
          | (Power + Network Core)|
          +-----------------------+
            |                |
   ┌────────┘                └────────┐
   v                                  v
+------------------+           +------------------+
|  Pi Cluster (Ainur)          |  x86 Cluster (Arda)
|  2x Raspberry Pi 5            |  4x HP ProDesk G4 Minis
|  Role: Bootstrap + PXE        |  Role: Talos Workloads
|------------------|            |------------------|
| Valar-1 (Primary)|            | Valinor-1 (Control Plane)
| Maiar-1 (Backup) |            | Valinor-2 (Control Plane)
|                  |            | Istari-1 (Worker)
| Runs:            |            | Istari-2 (Worker)
| - k3s cluster    |            +------------------+
| - PXE / TFTP /   |
|   DNSMasq        |
| - Git / ArgoCD   |
| - Longhorn backup|
| - Minio storage  |
+------------------+
```


![HP ProDesk 400 G4 Tiny Talos node, side profile](../../../assets/docs/about/architecture.png)
