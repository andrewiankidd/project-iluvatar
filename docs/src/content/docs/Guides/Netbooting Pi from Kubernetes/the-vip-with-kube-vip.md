---
title: The VIP with kube-vip
slug: guides/netbooting-pi-from-kubernetes/the-vip-with-kube-vip
description: Why the netboot stack needs a single virtual IP, and how a hostNetwork DaemonSet of kube-vip pods provides it.
sidebar:
  order: 3
draft: false
---

The single non-negotiable in this whole setup is: Pis ask DHCP option 66 "where do I boot from?" and get back **one** IP address. That IP has to keep working even as cluster nodes come and go. That's the VIP.

## Explanation

A "VIP" (Virtual IP) is an address that doesn't permanently belong to any one machine. Some node in the cluster claims it via ARP, answers traffic for it, and if that node falls over another node takes over the claim. From the LAN's perspective, the IP just keeps working.

I picked kube-vip for this because:

- It runs as a DaemonSet — every node is *capable* of holding the VIP, leader election picks one at a time.
- It's hostNetwork, so it can do raw ARP advertisement on the LAN interface.
- It's been in production at far larger scales than my home lab, and the failover behaviour is well-understood.

Things I considered and rejected:

- **A `LoadBalancer` Service with MetalLB.** Would work for TCP, but TFTP and NFS are UDP-heavy with port-pinning expectations (rpcbind, mountd) that don't survive a generic SNAT-style load balancer. Cleaner to bind on hostNetwork and let the VIP front it directly.
- **Pinning a node IP.** Easiest, but couples the cluster's storage layer to a specific node's lifecycle. If I rebuild that node, every Pi on the LAN suddenly can't boot.
- **DNS round-robin.** Pi firmware doesn't do A-record retry sanely.

So: kube-vip in control-plane mode, advertising one VIP, fronting hostNetwork DaemonSets.

## Implementation

### RBAC

```yaml
# src/manifests/ainur/pi-netboot/kube-vip.yaml (excerpt)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: ainur-netboot
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-vip
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: kube-vip
    namespace: ainur-netboot
```

`cluster-admin` is heavy. kube-vip needs a narrower set of permissions in practice, but the upstream docs ship a `cluster-admin` binding for the lab use-case and I haven't tightened it down. Worth doing if you take this past the home lab.

### The DaemonSet

```yaml
# src/manifests/ainur/pi-netboot/kube-vip.yaml (excerpt)
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-vip-tftp
  namespace: ainur-netboot
spec:
  selector:
    matchLabels:
      app: kube-vip-tftp
  template:
    spec:
      serviceAccountName: kube-vip
      hostNetwork: true
      tolerations:
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: kube-vip
          image: ghcr.io/kube-vip/kube-vip:v1.0.2
          args: ["manager"]
          securityContext:
            privileged: true
          env:
            - name: address
              value: "192.168.1.59"
            - name: vip_interface
              value: "eth0"
            - name: lb_enable
              value: "false"
            - name: cp_enable
              value: "true"
            - name: svc_enable
              value: "false"
            - name: cp_namespace
              value: "ainur-netboot"
            - name: vip_arp
              value: "true"
            - name: vip_leaderelection
              value: "true"
            - name: vip_namespace
              value: "ainur-netboot"
```

A few env vars warrant a comment:

- **`cp_enable: "true"` / `svc_enable: "false"` / `lb_enable: "false"`** — this is the slightly weird config. kube-vip can operate in "control-plane VIP" mode or "service load-balancer" mode. We don't actually have a control plane that needs a VIP (k3s clusters this small don't HA the API), but the `cp_enable` mode is the simplest one for "advertise this one address, full stop". Service-mode wants to watch `Service` objects and react to them, which isn't what we want here. So we use control-plane mode for what is, semantically, just "an address".
- **`vip_arp: "true"`** — Layer 2 ARP-based VIP, not BGP. Fine on a home LAN; you'd want BGP if your network is more grown-up.
- **`vip_leaderelection: "true"`** — uses K8s lease objects to decide which node holds the VIP. The losing nodes don't answer ARP for the VIP, the winner does.
- **`vip_interface: "eth0"`** — the LAN interface to advertise on. On a Pi this is `eth0`; on a different platform you may need to tweak. There's also a `vip_interface_auto: "true"` knob if you don't want to hardcode.
- **Tolerations** — without these the DaemonSet would refuse to schedule on the control-plane node, which is the one most likely to hold the VIP in a single-node lab.

### Why every kube-vip pod is the same

I called the DaemonSet `kube-vip-tftp` — the `-tftp` suffix is a vestige of when I was experimenting with one VIP per service. In practice they all use the same VIP because rpcbind/mountd/TFTP all need to advertise on a single address (any client expects them at the same IP). One DaemonSet, one VIP, three protocols sharing it.

## What you should see after this lands

```text
$ kubectl -n ainur-netboot get ds kube-vip-tftp
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
kube-vip-tftp   2         2         2       2            2

$ kubectl -n ainur-netboot get pods -l app=kube-vip-tftp -o wide
NAME                    READY   STATUS    NODE
kube-vip-tftp-abc12     1/1     Running   k3s-pi-leader
kube-vip-tftp-xyz34     1/1     Running   k3s-pi-worker-1

$ ip neigh | grep 192.168.1.59
192.168.1.59 dev eth0 lladdr e4:5f:01:xx:xx:xx REACHABLE
```

From any machine on the LAN, `ping 192.168.1.59` should return responses. To confirm which node currently holds it, check the kube-vip-leader lease:

```bash
kubectl -n ainur-netboot get lease | grep kube-vip
```

If the VIP isn't pingable, the most common cause is `vip_interface` being set to the wrong NIC name on a node that names interfaces differently (`enp0s3`, `wlan0`, etc.). kube-vip logs (`kubectl -n ainur-netboot logs ds/kube-vip-tftp`) say exactly what they couldn't bind to.

## Next Steps

We have a stable IP. Now we need files for it to serve — that's the [Builder Job →](./builder-job/).
