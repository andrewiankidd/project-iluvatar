---
title: The TFTP DaemonSet
slug: guides/netbooting-pi-from-kubernetes/tftp-daemonset
description: A hostNetwork DaemonSet running a containerised TFTP server with explicit hostPorts for the firmware data range.
sidebar:
  order: 5
draft: false
---

TFTP is the first protocol a Pi speaks at boot. The firmware ARP-resolves the VIP, asks for `config.txt` on UDP port 69, then negotiates a data transfer that bounces around a range of UDP ports.

## Explanation

A "TFTP server" sounds simple — and it is — but two things about UDP make this a non-trivial Kubernetes pod:

1. **Port 69 isn't enough.** TFTP's RRQ (Read Request) comes in on UDP/69, but the *data* transfer happens on a different port the server picks. Clients need to be able to reach that port too. Most TFTP servers let you pin the range.
2. **NAT / port-translation breaks things.** UDP NAT through a Service load balancer is a quagmire of half-open mappings and lost packets. The clean answer is `hostNetwork: true` and explicit `hostPort` declarations.

The image is [andrewkidd/tftp-server](https://github.com/andrewiankidd/tftp-server), a fork I built for the [original Pi-netboot Docker setup](../../Netbooting%20Raspberry%20Pi/3-srv-prep/). The fork mostly exists because the off-the-shelf TFTP images on Docker Hub at the time didn't ship ARM builds, and the few that did either didn't expose the port-range knobs the Pi firmware expects or had baked-in chroot paths that fought with `hostNetwork`. Building my own meant I could pin the data port range (`TFTPD_PORT_RANGE: 5000:5010`), drive everything from env vars, and ship multi-arch images that work on a Pi *and* on x86 nodes. The Kubernetes manifest here just wraps it; the config knobs are the same as in the Compose version.

## Implementation

```yaml
# src/manifests/ainur/pi-netboot/tftp-deployment.yaml (excerpt)
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: tftp
spec:
  selector:
    matchLabels:
      app: netboot
      component: tftp
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      tolerations:
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: tftp
          image: andrewkidd/tftp-server:v1.0.3
          imagePullPolicy: IfNotPresent
          env:
            - name: HOSTNETWORK
              value: "true"
            - name: TFTPD_LISTEN
              value: "true"
            - name: TFTPD_ADDRESS
              value: "0.0.0.0:69"
            - name: TFTPD_PORT_RANGE
              value: "5000:5010"
            - name: TFTPD_FOREGROUND
              value: "true"
            - name: TFTPD_DEBUG
              value: "true"
            - name: TFTPD_VERBOSITY
              value: "8"
            - name: TFTPD_SECURE_MODE
              value: "true"
            - name: TFTPD_DIRECTORIES
              value: "/var/tftpboot"
          ports:
            - { name: tftp, containerPort: 69, hostPort: 69, protocol: UDP }
            - { name: tftp-data, containerPort: 5000, hostPort: 5000, protocol: UDP }
            - { name: tftp-data2, containerPort: 5001, hostPort: 5001, protocol: UDP }
            # … through 5010 …
          volumeMounts:
            - name: boot
              mountPath: /var/tftpboot
      volumes:
        - name: boot
          persistentVolumeClaim:
            claimName: pi-netboot-boot
```

Things worth a comment:

- **`hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet`** — hostNetwork pods don't pick up cluster DNS by default. Setting `dnsPolicy` to `ClusterFirstWithHostNet` restores it for things that need to talk to cluster services.
- **`TFTPD_PORT_RANGE: "5000:5010"` plus matching `hostPort` declarations** — pinning the data ports lets us declare the right host ports up front. 10 ports is plenty for a small lab.
- **`TFTPD_SECURE_MODE: "true"`** — chroot into `/var/tftpboot`. Don't let a confused client list `/etc/shadow`.
- **`hostPort: 69` on every node** — only one process can bind UDP/69 on a node at a time. Since this is a DaemonSet, every node has exactly one of these pods, and they each own the port. If something else on the node is already listening on 69, the pod will fail to start.

### Why DaemonSet, not Deployment

A `Deployment` with `replicas: 1` would put TFTP on one node, and the VIP could land on any of them. If the VIP and the TFTP pod were on different nodes, traffic would arrive at one node and the only listener would be on another. `hostNetwork` means each pod only answers traffic on the node it's running on.

`DaemonSet` solves this by putting one TFTP pod on **every** node, so whichever node holds the VIP has a TFTP listening locally.

### Mount and content

The pod mounts the `pi-netboot-boot` PVC at `/var/tftpboot`. That's where the builder Job staged the firmware/kernel files. From the Pi's perspective:

- The Pi firmware asks for `config.txt`.
- TFTP serves it from `/var/tftpboot/config.txt`.
- `config.txt` references `kernel.img`, `cmdline.txt`, etc., all also in `/var/tftpboot`.
- `cmdline.txt` includes `root=/dev/nfs nfsroot=192.168.1.59:/...` — handing off to NFS.

### Commented-out sidecars

The manifest has a couple of debugging sidecars commented out:

```yaml
# - name: dmesg-tailer
#   ...
# - name: tcpdump
#   ...
```

If TFTP is misbehaving, uncomment the `tcpdump` one and tail its logs — you'll see every TFTP exchange with the Pi. Saved me a lot of grief during initial setup.

## What you should see after this lands

```text
$ kubectl -n ainur-netboot get ds tftp
NAME   DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
tftp   2         2         2       2            2

$ kubectl -n ainur-netboot logs ds/tftp | head -5
tftpd: Listening on 0.0.0.0:69 (UDP)
tftpd: Port range 5000-5010

$ tftp 192.168.1.59
tftp> get config.txt -
[config.txt contents printed]
```

If that last test fails ("Transfer timed out"), the most common causes are:

- Firewall on the node blocking UDP. Check `iptables -L -n` / `nft list ruleset`.
- VIP not actually held by a node running this DaemonSet. Run `kubectl -n ainur-netboot get pods -l component=tftp -o wide` and compare to where the VIP currently is.

## Next Steps

[The NFS DaemonSet →](./nfs-daemonset/) — this is where things get genuinely interesting.
