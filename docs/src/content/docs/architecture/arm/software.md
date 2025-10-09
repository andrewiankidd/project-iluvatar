---
title: ARM Software
description: Bootstrap services running on the Pi plane
draft: true
---

### OS: Ubuntu Server
The bootstrap plane runs lightweight Ubuntu Server images on Raspberry Pi 5s. Canonical’s ARM build gives me a familiar package ecosystem, smooth PoE/NVMe support, and enough flexibility to host the PXE, DNS, Git, and Argo seed workloads that bring new hardware online.

### Kubernetes (k3s)
k3s provides a tiny control plane that still feels like the Kubernetes I use everywhere else. The bootstrap cluster schedules PXE services, local Git mirrors, and the Argo CD seed app without needing separate VMs or one-off scripts.

### dnsmasq (proxy DHCP)
A hardened dnsmasq deployment hands out proxy-DHCP responses so existing routers keep their jobs while the Pis steer PXE-capable machines toward the right boot images. It also provides DNS for the homelab zones, letting me mirror upstream records when needed.

### PXE Services
The cluster exposes a TFTP/HTTP boot combo: tiny initrd and iPXE binaries live on TFTP, while larger Talos images are served over HTTP. New nodes netboot straight into Talos or bootstrap tooling without touching removable media.

### Argo CD Seed
I’ve used Argo products professionally for years. Even here, Argo CD bootstraps itself: the Pis run a seed instance that watches the Git repo and brings up the Talos control plane once bare-metal nodes appear.
