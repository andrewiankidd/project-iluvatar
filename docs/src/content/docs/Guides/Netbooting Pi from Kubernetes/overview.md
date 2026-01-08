---
title: Bootstrapping Kubernetes From Kubernetes
slug: guides/netbooting-pi-from-kubernetes/overview
description: Serve TFTP, NFS, and NoCloud HTTP straight from k3s using kube-vip, hostNetwork DaemonSets, and GitOps-managed assets.
sidebar:
  order: 1
draft: true
---
> The call is coming from inside the house

Run the entire netboot stack inside the cluster and boot Raspberry Pis from a kube-vip address—no external metal LB required.

## What Problem This Solves

- One VIP for all netboot services (TFTP, NFS, NoCloud HTTP) hosted inside k3s.
- No external load balancer needed; everything runs as hostNetwork DaemonSets.
- Repeatable GitOps pipeline: assets built by a job, served from PVCs, and exposed on the VIP.

## Prerequisites

- A working k3s cluster with hostNetwork support and a node-level VIP (see `src/manifests/ainur/pi-netboot/kube-vip.yaml`).
- RWX storage for boot/NFS exports (`pi-netboot-boot`, `pi-netboot-os`, etc. in `src/manifests/ainur/pi-netboot/pvcs.yaml`).
- DHCP handing out the VIP as the next-server and pointing TFTP to that VIP.
- Pi firmware set to netboot (EEPROM updated) and on the same L2 network as the VIP.

## What You Deploy

- **TFTP DaemonSet** (`src/manifests/ainur/pi-netboot/tftp-deployment.yaml`) on hostNetwork, serving `/var/tftpboot` from the boot PVC.
- **NFS DaemonSet** (`src/manifests/ainur/pi-netboot/nfs-deployment.yaml`) on hostNetwork, with debug sidecars and host rpcbind disabled so mountd/nfsd register on the VIP.
- **HTTP DaemonSet** (`src/manifests/ainur/pi-netboot/http-deployment.yaml`) on hostNetwork to serve cloud-init `user-data` / `meta-data`.
- **Builder Job** (`src/manifests/ainur/pi-netboot/builder-job.yaml`) that downloads/extracts the OS image and stages boot/NFS assets into the PVCs.
- **kube-vip DaemonSet** (`src/manifests/ainur/pi-netboot/kube-vip.yaml`) to advertise the VIP (e.g., `192.168.1.59`) at the node layer.

## Flow

1. Apply the pi-netboot kustomization (`src/manifests/ainur/pi-netboot/kustomization.yaml`) to provision PVCs, kube-vip, TFTP/NFS/HTTP, and run the builder job.
2. DHCP hands out the VIP as next-server; the Pi pulls bootcode/UEFI bits via TFTP.
3. The Pi’s kernel cmdline points to the NFS root on the VIP and fetches cloud-init data (`ds=nocloud;s=http://<VIP>/`).
4. NFS mount succeeds because mountd/nfsd register on the same rpcbind that owns port 111 on the VIP.
5. k3s/Argo (if included in your user-data) bootstrap the cluster on first boot.

## Verification Checklist

- `rpcinfo -p <VIP>` shows `100005 mountd` and `100003 nfs` on expected ports (111/2049/32767/32765 present).
- `tcpdump` on a node with the VIP shows TFTP (69/5000-5010), NFS (2049), and mountd (32767) traffic to/from the Pi.
- The HTTP DaemonSet serves `user-data` and `meta-data` at `http://<VIP>/`.

## VIP Configuration (kube-vip)

- **Why a VIP?** We do not want to hardcode a real node IP in DHCP or cloud-init. A Virtual IP lets us point clients at one stable address while Kubernetes decides which node holds it. If a node goes down, the VIP can move without reconfiguring clients.
- **How it’s provided:** `kube-vip.yaml` runs as a hostNetwork DaemonSet that answers ARP for the VIP (e.g., `192.168.1.59`). Because it’s a DaemonSet, every node is capable of holding the VIP.
- **Why this is “Kubernetes-native”:** The VIP is defined declaratively (YAML) and managed by a pod, not by manual node config. No SDN tricks or external load balancer are required.
- **Why not a LoadBalancer Service:** TFTP/NFS are UDP/portmap-heavy and don’t play nicely with typical Service load-balancing. Instead, we bind the services directly on the host network and let the VIP front them at L2.
- **Why not a fixed node IP:** Pinning to a node creates drift and breaks if that node is rebuilt. The VIP avoids per-node coupling while still keeping a single, predictable address for PXE/UEFI and cloud-init.

## TFTP Configuration (Challenges & Solutions)

- **Challenge:** TFTP needs host UDP ports 69 and a data port range to match firmware expectations; UDP is hard to load-balance.
- **Solution:** `tftp-deployment.yaml` is a hostNetwork DaemonSet with explicit `hostPort` mappings for 69 and 5000–5010. Debug sidecars (commented) are available for dmesg/tcpdump.
- **Tip:** Ensure DHCP `next-server` points to the VIP and the bootfile path matches what the builder job writes into the boot PVC.

## NFS Configuration (Challenges & Solutions)

- **Challenge:** mountd/nfsd must register on the same rpcbind that owns port 111 for the VIP; multiple rpcbind instances can hide mountd.
- **Solution:** `nfs-deployment.yaml` runs hostNetwork as a DaemonSet and includes an initContainer `disable-host-rpcbind` to stop/mask host rpcbind so the pod owns 111. It also loads kernel modules via `load-nfsd`.
- **Debug aids:** Optional dmesg/tcpdump sidecars; environment pins NFSv3, sets mountd/statd/lockd ports, and uses PVCs for `/mnt/nfsshare` and NFS state.
- **Verification:** `rpcinfo -p <VIP>` must show mountd/nfs entries; tcpdump should see 2049/32767 traffic.

## HTTP (Cloud-Init NoCloud)

- `http-deployment.yaml` is a hostNetwork DaemonSet serving from the boot PVC so `http://<VIP>/user-data` and `meta-data` are reachable.
- Keep the paths aligned with your Pi kernel cmdline (`ds=nocloud;s=http://<VIP>/`).

## Troubleshooting Notes

- If `rpcinfo -p <VIP>` only shows portmapper, ensure host rpcbind is disabled (see the `disable-host-rpcbind` initContainer in the NFS DaemonSet).
- Mismatched VIP holder vs. service node isn’t an issue here because all three services run as hostNetwork DaemonSets on every node.
- Keep an eye on inotify limits if mountd refuses to start; bump `fs.inotify.max_user_instances` on the VIP nodes if needed.
