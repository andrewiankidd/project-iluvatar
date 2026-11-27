---
title: The NFS DaemonSet
slug: guides/netbooting-pi-from-kubernetes/nfs-daemonset
description: NFSv3 from a hostNetwork DaemonSet — the rpcbind nightmare, the privileged init containers, and the reasons it has to be this way.
sidebar:
  order: 6
draft: false
---

This is the part that took me the longest. NFSv3 in a containerised, hostNetwork pod-on-Kubernetes context is genuinely difficult, and the init containers in this manifest exist for very specific reasons that I'm going to spell out because I forgot all of them once already and had to re-debug from scratch.

## Explanation

NFSv3 has multiple processes (`rpcbind`, `mountd`, `nfsd`, `statd`, `lockd`) that talk to each other via RPC. They register themselves with `rpcbind` on **UDP/TCP 111** so clients can ask "where's mountd?" and get back a port number.

Two things make this messy:

1. **`rpcbind` is a singleton.** Only one process can own port 111 on a given network namespace. If the host is running `rpcbind` (which Ubuntu does by default), and the pod is also running `rpcbind` on the same hostNetwork… one of them loses, and worse, *which* one loses is non-deterministic.
2. **`mountd` registers with whatever `rpcbind` answered first.** If host `rpcbind` is running and the pod's `rpcbind` registers `mountd` to the host's instance, NFS clients will hit the host `rpcbind` (port 111), be told `mountd` lives on port X, but actually `mountd` is bound to the pod's namespace and isn't reachable from the host's. The whole thing fails silently.

So: **the pod must own port 111**. That means stopping/masking the host's `rpcbind` from inside the pod. Which is a privileged operation. Which is why this pod is the way it is.

### About the container image

The image is [andrewkidd/nfs-server](https://github.com/andrewiankidd/nfs-server), which is a fork of [ehough/docker-nfs-server](https://github.com/ehough/docker-nfs-server). I went the fork route because the upstream image had two issues that mattered for me:

- **No ARM build.** [ehough/docker-nfs-server#77](https://github.com/ehough/docker-nfs-server/issues/77) tracked the request for ARM/arm64 images, which was open and unresolved when I needed it. The Raspberry Pi obviously can't run an x86 image, so a multi-arch build was non-negotiable.
- **rpcbind, mountd, and statd were not configurable enough for a hostNetwork pod.** [ehough/docker-nfs-server#34](https://github.com/ehough/docker-nfs-server/issues/34) covered the lack of port pinning for the RPC services. Without pinned `MOUNTD_PORT` / `STATD_PORT` / `LOCKD_*` env vars, every restart picks fresh ephemeral ports, which is a mess on hostNetwork where you want predictable port numbers across nodes. I [submitted ehough/docker-nfs-server#95](https://github.com/ehough/docker-nfs-server/pull/95) with the changes that finally let me run it inside a DaemonSet sanely.

The fork is `andrewkidd/nfs-server`; the image tag in this manifest (`v2.2.7`) is from that fork. If you trace this back to the [original Pi-netboot guide](../../Netbooting%20Raspberry%20Pi/3-srv-prep/) you'll notice the same image was used in the Docker Compose version — turns out a container that works on hostNetwork in Docker also works on hostNetwork in Kubernetes, with most of the same env vars and the same privileged-mode requirements.

## Implementation

Reading [nfs-deployment.yaml](../../../../../../src/manifests/ainur/pi-netboot/nfs-deployment.yaml) top to bottom:

### Three init containers, doing three different unpleasant things

```yaml
initContainers:
  - name: tune-inotify
    # bumps fs.inotify limits via nsenter into pid 1's namespace
  - name: disable-host-rpcbind
    # stops/disables/masks the host's rpcbind via nsenter + systemctl
  - name: load-nfsd
    # modprobes nfsd/nfs/lockd, sets up /var/lib/nfs state, mounts /proc/fs/nfsd
```

Each of these uses `nsenter --mount=/proc/1/ns/mnt --pid=/proc/1/ns/pid` to break out into the host's mount and PID namespaces. Without that, `systemctl` inside the pod would just talk to its own (empty) systemd; we need it to talk to the *host's* systemd to disable host services.

#### `tune-inotify`

```yaml
- name: tune-inotify
  image: alpine:3.20
  securityContext:
    privileged: true
  command: ["/bin/sh","-c"]
  args:
    - |
      nsenter --mount=/proc/1/ns/mnt --pid=/proc/1/ns/pid -- sysctl -w \
        fs.inotify.max_user_instances=512 \
        fs.inotify.max_user_watches=524288 || true
```

`rpc.mountd` opens inotify watches on `/etc/exports.d/` and a few related paths. On a default Ubuntu Pi, the kernel inotify limits are low enough that mountd can fail with `EMFILE` ("too many open files") on a busy cluster. Bumping these values on the host makes the failure go away.

I tried setting these via a `securityContext.sysctls` on the pod first; turns out `fs.inotify.*` aren't namespaced and have to be set on the host, hence the nsenter dance.

#### `disable-host-rpcbind`

```yaml
- name: disable-host-rpcbind
  image: alpine:3.20
  securityContext:
    privileged: true
  command: ["/bin/sh","-c"]
  args:
    - |
      nsenter --mount=/proc/1/ns/mnt --pid=/proc/1/ns/pid -- sh -c '
        systemctl stop rpcbind.socket rpcbind.service || true
        systemctl disable rpcbind.socket rpcbind.service || true
        systemctl mask rpcbind.socket rpcbind.service || true
      '
```

This is the load-bearing one. Stop the host's `rpcbind`, disable it (so it doesn't restart on next boot), and mask it (so nothing accidentally starts it).

Once this runs, port 111 on the host network namespace is free for the pod's `rpcbind` to claim. Which it does as soon as the main container starts.

#### `load-nfsd`

```yaml
- name: load-nfsd
  image: alpine:3.20
  securityContext:
    privileged: true
  command: ["/bin/sh","-c"]
  args:
    - |
      apk add --no-cache kmod util-linux >/dev/null 2>&1 || true
      modprobe nfsd || true
      modprobe nfs || true
      modprobe lockd || true
      mkdir -p /var/lib/nfs/rpc_pipefs /var/lib/nfs/sm /var/lib/nfs/sm.bak /var/lib/nfs/v4recovery
      : > /var/lib/nfs/state
      chown 0:0 /var/lib/nfs/state && chmod 600 /var/lib/nfs/state || true
      nsenter --mount=/proc/1/ns/mnt -- sh -c '
        if ! mountpoint -q /proc/fs/nfsd 2>/dev/null; then
          mount -t nfsd nfsd /proc/fs/nfsd || true
        fi
        if [ -w /proc/fs/nfsd/versions ]; then
          printf -- "-2 +3 -4 -4.1 -4.2\n" > /proc/fs/nfsd/versions 2>/dev/null || true
        fi
      '
  volumeMounts:
    - name: modules
      mountPath: /lib/modules
      readOnly: true
    - name: nfs-state
      mountPath: /var/lib/nfs
```

Three jobs here:

1. **Load kernel modules.** The NFS server runs in userspace but `nfsd` itself is a kernel facility. `modprobe nfsd/nfs/lockd` makes sure the kernel is ready.
2. **Initialise `/var/lib/nfs` on the persistent volume.** This is the state directory NFS uses for `sm`/`sm.bak`/`v4recovery`. Putting it on a PVC means recovery state survives pod restarts.
3. **Pin NFSv3 only.** Writing `-2 +3 -4 -4.1 -4.2` to `/proc/fs/nfsd/versions` disables NFSv2 (long-deprecated) and the v4 family. The Pi firmware [can't boot from NFSv4](https://bugs.launchpad.net/ubuntu/+source/linux-raspi/+bug/1954716) anyway. Disabling v4 also silences the "Unsupported version" warnings that would otherwise spam dmesg.

### The main container

```yaml
containers:
  - name: nfs
    image: andrewkidd/nfs-server:v2.2.7
    securityContext:
      privileged: true
      capabilities:
        add: [SYS_ADMIN]
    lifecycle:
      postStart:
        exec:
          command: ["/bin/sh","-c","mkdir -p /var/lib/nfs/rpc_pipefs"]
    env:
      - { name: NFS_VERSION, value: "3" }
      - { name: NFS_EXPORT_0, value: "/mnt/nfsshare *(rw,fsid=0,async,no_subtree_check,no_auth_nlm,insecure,no_root_squash)" }
      - { name: NFS_LOG_LEVEL, value: "DEBUG" }
      - { name: MOUNTD_PORT, value: "32767" }
      - { name: STATD_PORT, value: "32765" }
      - { name: LOCKD_TCPPORT, value: "4045" }
      - { name: LOCKD_UDPPORT, value: "4045" }
    ports: # 111, 2049, 4045, 32765, 32767 both TCP and UDP
    volumeMounts:
      - { name: os, mountPath: /mnt/nfsshare }
      - { name: nfs-state, mountPath: /var/lib/nfs }
volumes:
  - name: os
    persistentVolumeClaim: { claimName: pi-netboot-os }
  - name: modules
    hostPath: { path: /lib/modules, type: Directory }
  - name: nfs-state
    persistentVolumeClaim: { claimName: pi-netboot-nfs-state }
```

Key bits:

- **`privileged: true` + `SYS_ADMIN`** — needed to mount `nfsd`, manage exports, listen on privileged ports.
- **`fsid=0`** in the export — makes `/mnt/nfsshare` the root of the NFS namespace. The Pi cmdline can then mount it directly with `nfsroot=192.168.1.59:/`.
- **`no_auth_nlm` and `insecure`** — disable client port restrictions (clients can come from non-privileged ports), and disable lock manager auth. Necessary because the Pi firmware is not running with a particularly opinionated NFS client.
- **`no_root_squash`** — UID 0 inside the NFS share is real UID 0. Required because the Pi runs as root during early boot.
- **Pinned ports for mountd/statd/lockd** — without pinning, these would pick ephemeral ports on each startup, and any firewall rules you wrote would go stale.
- **`/lib/modules` hostPath** — the pod uses the host's kernel modules to `modprobe nfsd`. Without this, the modprobe would fail because the container image has no modules for the host kernel.

## What you should see after this lands

```text
$ kubectl -n ainur-netboot get ds nfs
NAME   DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
nfs    2         2         2       2            2

$ rpcinfo -p 192.168.1.59
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    4   udp    111  portmapper
    100005    3   udp  32767  mountd
    100005    3   tcp  32767  mountd
    100003    3   udp   2049  nfs
    100003    3   tcp   2049  nfs
    100024    1   udp  32765  status
    100024    1   tcp  32765  status

$ showmount -e 192.168.1.59
Export list for 192.168.1.59:
/mnt/nfsshare *
```

If `rpcinfo` only shows `portmapper` and no `mountd`/`nfs`, then **the host's `rpcbind` is still running**. Confirm with `ssh node 'systemctl status rpcbind'` — should be `inactive (dead)`. If it's running, the `disable-host-rpcbind` initContainer didn't do its job; check the pod's init container logs.

## Next Steps

[HTTP + Bootstrap →](./http-and-bootstrap/) — the third hostNetwork pod, plus the clever k3s leader-token share.
