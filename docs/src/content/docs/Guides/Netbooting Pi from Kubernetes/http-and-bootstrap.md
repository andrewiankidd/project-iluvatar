---
title: HTTP & Bootstrap
slug: guides/netbooting-pi-from-kubernetes/http-and-bootstrap
description: The HTTP DaemonSet serves cloud-init NoCloud and the k3s leader/agent-token files. Two jobs in one pod.
sidebar:
  order: 7
draft: false
---

The last piece of the netboot trio is plain HTTP — but it's doing two jobs at once, and one of them is the trick that makes the whole "boot a new node and have it join the cluster" story work.

## Explanation

The HTTP DaemonSet serves two kinds of file:

1. **Cloud-init NoCloud data.** When a Pi has finished its NFS root mount, it runs cloud-init, which expects to find `user-data` / `meta-data` at `http://<bootstrap-ip>/`. The Pi's kernel cmdline points at our VIP for this.
2. **k3s leader IP and agent-token.** Because the [Ephemeral K3s leader-election scripts](../Ephemeral%20K3s%20Cluster/deploying-k3s-on-netboot-nodes/) write `/tmp/k3s/k3s-leader` and `/tmp/k3s/k3s-agent-token` on whichever node is currently the leader, and any *new* Pi joining the cluster needs to know both. So we re-share those files via HTTP from the leader.

The same pod, the same hostNetwork, but two completely different consumers.

:::note[Since 2026-11-19 the token isn't served]
What follows is how this was first built. Now only `k3s-leader` is served: a booting Pi waits for its agent token to be pushed over SSH by ainur's `secrets-pusher` (`bootstrap/netboot/scripts/push-secrets.sh`), using a key whose public half is the only credential in its image. See [the .env reference](../../../reference/env/).
:::

:::caution[This is the spiciest endpoint in the whole stack]
The agent-token file served at `http://<VIP>/k3s/k3s-agent-token` (and `http://bootstrap.kidd.network/k3s/k3s-agent-token`) is the **k3s join token, plain text, unauthenticated, over plain HTTP**. Anyone who can reach this endpoint can `curl` the token and bring up a node that joins your cluster as an agent — which is enough to schedule pods on shared hardware and read whatever hostPaths your workloads use.

There's no auth layer here. The entire security model is "the LAN is trusted." Run this on a private VLAN or behind a firewall that restricts who can reach the VIP. If you ever expose this stack on a less-trusted network, this is the first thing to put behind mTLS or rip out entirely.
:::

## Implementation

### The DaemonSet

```yaml
# src/manifests/ainur/pi-netboot/http-deployment.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: bootstrap-http
spec:
  selector:
    matchLabels:
      app: netboot
      component: http
  template:
    spec:
      tolerations:
        - { key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule }
        - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
      initContainers:
        - name: verify-volume-mounts
          image: busybox:1.36
          command: ["sh","-c"]
          args:
            - |
              test -d /boot || exit 1
              test -f /mnt/k3s/k3s-leader
              test -f /mnt/k3s/k3s-agent-token
          volumeMounts:
            - { name: boot, mountPath: /boot }
            - { name: k3s-leader, mountPath: /mnt/k3s/k3s-leader }
            - { name: k3s-agent-token, mountPath: /mnt/k3s/k3s-agent-token }
      containers:
        - name: nginx
          image: nginx:alpine
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - |
                  test -f /usr/share/nginx/html/k3s/k3s-leader && \
                  test -f /usr/share/nginx/html/k3s/k3s-agent-token
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - { name: boot, mountPath: /usr/share/nginx/html }
            - { name: k3s-leader, mountPath: /usr/share/nginx/html/k3s/k3s-leader, readOnly: true }
            - { name: k3s-agent-token, mountPath: /usr/share/nginx/html/k3s/k3s-agent-token, readOnly: true }
      volumes:
        - name: boot
          persistentVolumeClaim:
            claimName: pi-netboot-boot
        - name: k3s-leader
          hostPath:
            path: /tmp/k3s/k3s-leader
            type: File
        - name: k3s-agent-token
          hostPath:
            path: /tmp/k3s/k3s-agent-token
            type: File
```

Three things worth unpacking:

#### `verify-volume-mounts` initContainer

This pod has a hard dependency on two host files existing: `/tmp/k3s/k3s-leader` and `/tmp/k3s/k3s-agent-token`. They're produced by the k3s leader-election scripts ([k3s-10-leader-election.sh](../Ephemeral%20K3s%20Cluster/deploying-k3s-on-netboot-nodes/#k3s-10-leader-electionsh-whos-the-boss)) on whatever node is currently leader.

The initContainer just `test -f`s those files. If they don't exist, the pod crashloops at init until they do. This is by design — a `bootstrap-http` pod that started without them would serve nginx 404s for `/k3s/k3s-leader`, and a Pi mid-boot trying to fetch leader/token info would silently fail to join.

:::caution[First boot of the very first node]
On a brand-new cluster, the very first node is its own leader and `/tmp/k3s/k3s-leader` won't exist until after k3s-bootstrap.service has finished its leader-election pass. The HTTP DaemonSet will crashloop until that happens. This is fine — it's the natural ordering: K3s comes up → leader-election writes the files → bootstrap-http unblocks → newly booting Pis can ask for them.

If you're following along on a *non-K3s* cluster or skipped the leader-election scripts, you'll need to put those two files at `/tmp/k3s/` on each node yourself (a leader IP and an agent join token of your choosing).
:::

#### Two consumers, one pod

The `boot` volume (the `pi-netboot-boot` PVC) is mounted at `/usr/share/nginx/html`. So `http://<VIP>/user-data` reaches files the builder wrote into that PVC.

The two hostPath files are mounted at `/usr/share/nginx/html/k3s/k3s-leader` and `…/k3s-agent-token`. So `http://<VIP>/k3s/k3s-leader` returns the IP, and `http://<VIP>/k3s/k3s-agent-token` returns the token.

By using **bind mounts on top of the boot PVC's mount**, nginx ends up serving a hybrid filesystem: most paths come from the PVC, but `/k3s/k3s-leader` and `/k3s/k3s-agent-token` come from the host. Neat.

#### Readiness probe

```yaml
readinessProbe:
  exec:
    command:
      - sh
      - -c
      - |
        test -f /usr/share/nginx/html/k3s/k3s-leader && \
        test -f /usr/share/nginx/html/k3s/k3s-agent-token
```

Even if the initContainer passed, the readiness probe re-checks every 5 seconds. If a hostPath file disappears (e.g. somebody clears `/tmp/k3s/` on the leader node), the pod goes unready, which propagates to the Service load-balancing (see below).

### Service and Ingress

```yaml
# src/manifests/ainur/pi-netboot/http-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: bootstrap-http
  namespace: ainur-netboot
spec:
  type: ClusterIP
  selector:
    app: netboot
    component: http
  ports:
    - { name: http, port: 80, targetPort: 80, protocol: TCP }
  externalIPs:
    - 192.168.1.59
```

```yaml
# src/manifests/ainur/pi-netboot/http-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bootstrap-http
  namespace: ainur-netboot
  annotations:
    kubernetes.io/ingress.class: "traefik"
spec:
  ingressClassName: traefik
  rules:
    - host: bootstrap.kidd.network
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: bootstrap-http
                port:
                  number: 80
```

Notice **two** ways to reach the HTTP service:

- **`externalIPs: [192.168.1.59]`** on the Service — kube-proxy installs rules so that traffic to the VIP on port 80 is routed to ready pods of this Service. Belt-and-braces with the hostNetwork + VIP arrangement; in practice the hostNetwork pod already binds 80 on the VIP-holding node, so the externalIPs route is rarely used but doesn't hurt.
- **`bootstrap.kidd.network` Ingress via Traefik** — gives us a hostname for the same files, useful for browser access ("did the build write what I expected?") and for the [Ephemeral K3s leader-election script](../Ephemeral%20K3s%20Cluster/deploying-k3s-on-netboot-nodes/#k3s-10-leader-electionsh-whos-the-boss), which uses `http://bootstrap.kidd.network/k3s/k3s-leader` to discover the leader from non-cluster nodes.

### Why hostNetwork on this one too

Same reason as TFTP and NFS: the VIP needs to land on a node that has a listener on port 80 ready to serve. hostNetwork + DaemonSet = every node has the listener.

## What you should see after this lands

```text
$ kubectl -n ainur-netboot get ds bootstrap-http
NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
bootstrap-http   2         2         2       2            2

$ curl -s http://192.168.1.59/k3s/k3s-leader
192.168.1.52

$ curl -s http://192.168.1.59/k3s/k3s-agent-token | head -c 40
K10abcdef0123456789abcdef0123456789abcdef::

$ curl -s http://bootstrap.kidd.network/user-data | head -3
#cloud-config
hostname: pi-${random}
…
```

If the pod is `Pending` indefinitely, the initContainer check failed. `kubectl -n ainur-netboot describe pod -l component=http` will show which file was missing, and `ls -l /tmp/k3s/` on the suspect node will confirm.

## Next Steps

You now have all four pieces — VIP, TFTP, NFS, HTTP — running from inside the cluster. The [Summary →](./summary/) wraps it up and notes what's still on my "would clean up" list.
