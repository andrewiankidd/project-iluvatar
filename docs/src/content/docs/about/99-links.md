---
title: Resources
description: Open Source
draft: true

---

I had a lot to learn while building this cluster. Thousands of tabs were opened and closed, hundreds were re-opened over and over. Here are the few I can remember

## Core Technologies

The main tech stack that makes up the cluster

### K3s
K3s is a lightweight Kubernetes distribution designed for production workloads in resource-constrained environments. It is optimized for ARM processors and low-resource devices, making it ideal for edge computing, IoT, and small-scale deployments. K3s simplifies the Kubernetes installation process and reduces the memory and CPU footprint, while still providing the full Kubernetes API.

[K3s](https://k3s.io)

### Talos Linux
Talos is an immutable, API-driven Linux distribution built specifically for Kubernetes control planes and nodes. It ships without a shell, keeping each machine declarative and reducing configuration drift. Talos integrates directly with Kubernetes, enabling fully automated lifecycle management from Git commits all the way to running workloads.

[Talos Linux](https://www.talos.dev)

### Raspberry Pi
Raspberry Pi is a series of affordable, small, and versatile single-board computers. These devices are widely used in education, hobbyist projects, and industrial applications due to their low cost, ease of use, and extensive community support. Raspberry Pi boards can run a variety of operating systems and are capable of handling a wide range of tasks, from simple automation to complex computing projects.

[Raspberry Pi](https://www.raspberrypi.org)

## Hardware

This is a list of the specific hardware I'm using in my cluster, not to say others wouldn't work, YMMV.

### Pi
- [Raspberry Pi 5 8GB](https://thepihut.com/products/raspberry-pi-5?variant=42531604955331): The latest Raspberry Pi model with 8GB of RAM.
- [PoE+ NVMe HAT](https://www.amazon.co.uk/dp/B0D8J7B47N): A Power over Ethernet plus NVMe HAT for Raspberry Pi.
- [NVMe SSD](https://www.amazon.co.uk/gp/product/B0822Y6N1C/): A high-speed NVMe SSD for storage.
- [SD Card](https://www.amazon.co.uk/dp/B07R7C3PW5/): A reliable SD card for Raspberry Pi.

### Network
- [PoE Switch](https://uk.store.ui.com/uk/en/products/usw-pro-24-poe): A PoE switch for network connectivity.
- (OR) [PoE Injector](https://www.amazon.co.uk/dp/B08LQP8CYD): An alternative to the PoE switch for providing power over Ethernet.

## Software
### Operating Systems
- [Talos Linux](https://www.talos.dev): Immutable, Kubernetes-focused operating system for the x86 workload cluster.
- [Ubuntu Server](https://ubuntu.com/download/server): Lightweight ARM build powering the Raspberry Pi bootstrap plane.
- [Raspberry Pi OS](https://www.raspberrypi.org/software/): Handy for quick diagnostics and flashing when Pis misbehave.

### Containerization
- [Docker](https://www.docker.com): A platform for developing, shipping, and running applications in containers.
- [Multipass](https://multipass.run): A tool to launch and manage lightweight Ubuntu VMs.

### Docker Containers
- [pghalliday/tftp](https://hub.docker.com/r/pghalliday/tftp): A TFTP server container used for hosting boot files.
- [erichough/nfs-server](https://hub.docker.com/r/erichough/nfs-server): An NFS server container used for hosting OS files.

### Additional Tools
- [Helm](https://helm.sh): A package manager for Kubernetes.
- [Longhorn](https://longhorn.io): A distributed block storage system for Kubernetes.
- [ArgoCD](https://argoproj.github.io/argo-cd/): A declarative, GitOps continuous delivery tool for Kubernetes.

### Documentation Site
- [Astro](https://astro.build): A modern static site builder.
- [Starlight](https://starlight.astro.build): A theme for building documentation sites with Astro.

### Sources
- [Project Repository](https://github.com/andrewiankidd/project-iluvatar): The GitHub repository for this project.
- [Starlight Starter Kit](https://github.com/withastro/starlight/tree/main/examples/basics): The GitHub repository for the Starlight Starter Kit.
*** End Patch

## Documentation
Tutorials / Steps / Guides / Wikis / Forum Posts in no particular order

### Talos
- [Talos Documentation](https://www.talos.dev/docs/)
- [Talos Quickstart for Proxmox](https://www.talos.dev/v1.7/talos-guides/install/cloud/proxmox/)
- [Sidero Labs Blog](https://www.siderolabs.com/blog/)
- [SOPS](https://github.com/google/sops)

### Netboot
- [PXE Booting Raspberry Pis](https://ltm56.com/pxe-booting-raspberry-pis/)
- [Raspberry Pi PXE Boot – Network booting a Pi 4 without an SD card](https://linuxhit.com/raspberry-pi-pxe-boot-netbooting-a-pi-4-without-an-sd-card/)

### Cloudflare
 - [Cloudflare Docs](https://developers.cloudflare.com)
