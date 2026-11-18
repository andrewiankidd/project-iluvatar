---
title: 'Summary & Next Steps'
slug: guides/netbooting-pi-from-kubernetes/summary
description: What this whole stack is, what I'd still clean up about it, and where it leads next.
sidebar:
  order: 8
draft: false
---

I'm pretty pleased with this one. The original Pi-netboot setup was the dependency that bugged me most about the cluster — a Docker box on the side that had to exist before anything else could. Moving the whole thing into the cluster the Pis boot into closes the loop in a way that genuinely feels recursive.

## Recap

Over this section I:

- moved TFTP, NFS, and HTTP from a host-based Docker setup into in-cluster hostNetwork DaemonSets;
- fronted them with a kube-vip Virtual IP so the LAN sees a single, stable boot address;
- backed them with Longhorn RWX PVCs so any node could serve any file, and later swapped those for local-path on valar-50, with everything pinned beside it, when Longhorn proved too heavy for the netbooted Pis;
- staged Ubuntu images into those PVCs via a one-shot `Job` that sparse-clones this repo;
- made the HTTP pod serve both cloud-init NoCloud data *and* the k3s leader IP / agent-token, so freshly netbooted Pis have everything they need to join the cluster they just booted from.

The really nice side-effect: once this is up, the original Docker netboot host is no longer load-bearing. I can shut it down and the existing Pis keep working, and new Pis can boot using the cluster they're about to join. The dependency graph is finally a circle, not a chain hanging off an external box.

## What's still rough

Honest about the corners I cut:

- **kube-vip has `cluster-admin` RBAC.** It needs less than that. Worth tightening the ClusterRoleBinding to a real role at some point.
- **NFS DaemonSet runs `privileged: true`.** Unavoidable for some of the rpcbind/modprobe gymnastics, but I'd love to revisit with `securityContext.capabilities.add` instead of full privileged mode and see how far I can get.
- **`pi-netboot-builder:latest` is unpinned.** I'd rather pin a version. The builder is my own image so the blast radius is small, but `:latest` is still a bad habit.
- **HostPath hostility.** `/lib/modules` (NFS) and `/tmp/k3s/k3s-*` (HTTP) are both bound directly off the host. Move the cluster to a different host OS and these break. Worth documenting in the [reference](../../Reference/cluster-storage-notes/) page if/when that gets written.
- **Builder pulls from GitHub every run.** Airgap-hostile. A small `git-server` Service in the cluster could host a mirror, or the builder image could ship pre-baked with the assets — neither is hard, just hasn't been a priority.
- **TFTP, NFS, *and the agent-token endpoint* have no AuthN/Z whatsoever.** Same security caveat as the original [Pi-netboot section](../../Netbooting%20Raspberry%20Pi/1-about-pi-netboot/#explanation), only worse: the cluster's k3s join token is now also being served unauthenticated over plain HTTP at `bootstrap.kidd.network/k3s/k3s-agent-token` (see the [HTTP page](./http-and-bootstrap/#this-is-the-spiciest-endpoint-in-the-whole-stack)). The VLAN is doing 100% of the security work. Anyone on the LAN can pull the token and join the cluster.
- **`pi-netboot-env` ConfigMap has a misleading default.** `BOOTSTRAP_IP_ADDRESS: "SET_AUTOMATICALLY_VIA_HOSTIP"` reads like it's about to do something dynamic, but the Job overrides it via explicit env. Worth either tidying the comment or finally making `valueFrom: hostIP` work.

## Where this leads

The cluster can now boot itself. That unlocks a few interesting things:

- **More Pi workers can join unattended.** Power them on, DHCP points them at the VIP, they boot through TFTP+NFS, run k3s-bootstrap, contact `bootstrap.kidd.network` for the leader IP and agent token, and they're in. The "manual" steps from the original guide are no longer needed.
- **The original Docker netboot box can be retired.** I haven't actually killed it yet because it makes a useful "rescue boot" option if the cluster is down, but functionally it's redundant.
- **x86 / Talos provisioning becomes the next chapter.** With Pi netboot solved cluster-internally, the same general pattern (VIP, hostNetwork DaemonSets, RWX storage) can be applied to a [Sidero Omni](../../Architecture/x86/) deployment serving Talos to x86 nodes. The exact protocols differ (PXE rather than Pi-firmware netboot), but the shape of the solution is similar.

## Where it sits in the bigger picture

This is the third "load-bearing" guide in the project so far, after [Diskless Pi Netboot](../../Netbooting%20Raspberry%20Pi/) and [Ephemeral K3s Cluster](../../Ephemeral%20K3s%20Cluster/). Together they describe how the cluster pulls itself up by its own bootstraps: a Pi boots without an SD card, joins an ephemeral cluster, and that cluster hosts the stack that boots the *next* Pi.

The next milestone is to do the same with x86 hardware, which is where Talos / Sidero Omni come in — and where my [self-signed SSO work](../Self%20Signed%20Cluster%20SSO/) was originally heading before I got stuck on Omni's TLS expectations.

[← Back to the Guides index](./../../)
