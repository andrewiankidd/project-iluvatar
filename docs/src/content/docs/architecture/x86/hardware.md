---
title: x86 Hardware
description: Nodes powering the Talos workload cluster
draft: true
---


![HP ProDesk 400 G4 Tiny Talos node, side profile](../../../../assets/docs/about/hp-node.png)

Again I wanted something low power, powerful and could potentially run off of PoE for remote power management.

Used office computers are your best bet, so onwards to ebay

#### Configuration
I landed on some refurbished "HP ProDesk 400 G4 USFF Mini PC"s to run the workload cluster. They landed at roughly £110 per node, which seems pretty good for eighth-gen Intel silicon and NVMe storage in this footprint.

| Model                 | CPU       | RAM  | Storage       | Cost (each) | Cluster Role |
|-----------------------|-----------|------|---------------|-------------|--------------|
| HP ProDesk 400 G4 USFF| i5-8500T  | 16 GB| 256 GB NVMe   | ~£110       | Talos worker |

They PXE boot Talos without drama, idle below 20 W, and are partially upgradable as workloads scale.

#### Alternatives Considered
I looked for a while and read up on different suggestions, some other options came close.

| Model                            | CPU       | RAM  | Storage | Typical price | Notes |
|----------------------------------|-----------|------|---------|---------------|-------|
| Dell OptiPlex 3060 Micro         | i5-8500T  | 16 GB| 500 GB  | ~£150         | Much higher per-node cost |
| Lenovo ThinkCentre M910q         | i5-7500T  | 16 GB| 256 GB  | £120–£130     | 7th gen cpu |

Those options would have worked, but the ProDesk deal struck the right balance.
