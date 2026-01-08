---
title: Defining a Cluster via Cloud-Init
slug: guides/ephemeral-netboot-pi-cluster/cloud-init-cluster
description: Walkthrough of a cloud-init that boots a single-node K3s server.
sidebar:
  order: 2
draft: false
---

This guide covers the process of automatically configuring a K3s cluster / control plane node via Cloud-Init.

## Explanation

There are a multitude of ways to automate this kind of setup, and the method I'm about to outline below likely is overkill for most scenarios, however for reasons that will be revealed later it's beneficial for me to do it this way.

I'll be using Cloud-Init `write_files` section to prepare a number of scripts, as well as defining a `k3s-bootstrap` systemd service which is used to execute these scripts.

The benefit of this is I can manage the resulting `k3s-bootstrap`, `k3s` and `k3s-agent` services all via `systemctl` as well as view their logs with `journalctl`

### Components
- `k3s-bootstrap.sh` - A base orchestrator script that identifies all following  `k3s-*.sh` scripts and runs them in order.
- `k3s-20-install.sh` - Actions the actual download and installation of k3s
- `k3s-bootstrap.service` - Systemd related glue to make these scripts actionable services that will run automatically as part of the systems boot process.

## Implementation

### Bootstrap orchestrator
First we define `/usr/local/bin/k3s-bootstrap.sh` with `write_files`.

This scripts duties are simple, it checks for any scripts matching `/usr/local/bin/k3s-[0-9][0-9]-*.sh` naming convention and run them in order.

This allows me to break the process up into multiple extendable components that can be enabled/disabled easily instead of one huge script

```yaml
# cloud-config
write_files:
  - path: /usr/local/bin/k3s-bootstrap.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      shopt -s nullglob
      scripts=(/usr/local/bin/k3s-[0-9][0-9]-*.sh)
      if [ ${#scripts[@]} -gt 0 ]; then
        mapfile -t scripts < <(printf '%s\n' "${scripts[@]}" | sort -V)
        for s in "${scripts[@]}"; do
          bash "$s"
        done
      fi
```

### Server-only installer
For now we're focused on a single node, control-plane only cluster for proof of concept.

The script has some basic variables used for controlling the configuration, in this example pinning `INSTALL_K3S_VERSION="v1.33.6+k3s1"`, hardcoding `K3S_ROLE=server` and calling the upstream installer with `--cluster-init` and an explicit control-plane label to make it clear we're defining the control plane node here.

```yaml
# cloud-config
write_files:
  - path: /usr/local/bin/k3s-20-install.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      INSTALL_K3S_VERSION="v1.33.6+k3s1"
      K3S_ROLE="server"
      K3S_TOKEN="my-cluster-token"
      K3S_COMMON_ARGS=""
      K3S_SERVER_ARGS=" --cluster-init --node-label=kidd.network/role=control-plane --token ${K3S_TOKEN}"
      curl -sfL https://get.k3s.io | \
        K3S_TOKEN="$K3S_TOKEN" \
        INSTALL_K3S_EXEC=" $K3S_COMMON_ARGS $K3S_SERVER_ARGS" \
        INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
        sh -s -
```

Between these two scripts we should be able to get k3s up, but we want it to happen automatically at boot, so we need to wrap it in a systemd service.

### Systemd wiring
To bring this all together, we define a systemd unit: `k3s-bootstrap.service`.

This unit runs once networking is up and hands off to the orchestrator scripts we defined.



```yaml
# cloud-config (k3s bootstrap)
write_files:
  - path: /etc/systemd/system/k3s-bootstrap.service
    permissions: '0644'
    content: |
      [Unit]
      Description=K3s Bootstrap (server-only)
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/k3s-bootstrap.sh
      Restart=on-failure
      RestartSec=10s

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, k3s-bootstrap.service ]
```

### Bundled Manifest Installation

We can also use systemd to trigger custom logic after the k3s installation process completes.

In this example, when K3s creates its `/etc/rancher/k3s/k3s.yaml` file, the `k3s-ready.path` unit triggers a copy of anything in the directory `/etc/k3s-manifests` into the live manifests directory.

This lets us define manifests that can be installed to k3s automatically as soon as it's ready to consume them.


```yaml
# cloud-config (k3s manifest install)
write_files:
  - path: /usr/local/sbin/k3s-install-manifests.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      src="/etc/k3s-manifests"
      dst="/var/lib/rancher/k3s/server/manifests"
      shopt -s nullglob
      for f in "$src"/*.yaml "$src"/*.yml; do
        b=$(basename "$f")
        install -D -m0644 "$f" "$dst/$b"
      done

  - path: /etc/systemd/system/k3s-manifests-install.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Install all staged k3s manifests
      Wants=k3s.service
      After=k3s.service
      ConditionPathExists=/var/lib/rancher/k3s/server/manifests

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/k3s-install-manifests.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/k3s-ready-dispatch.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Dispatch post-k3s setup when ready
      After=k3s.service

      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'systemctl start k3s-manifests-install.service || true'

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/k3s-ready.path
    permissions: '0644'
    content: |
      [Unit]
      Description=Trigger post-k3s setup when k3s is ready

      [Path]
      PathExists=/etc/rancher/k3s/k3s.yaml
      PathExists=/var/lib/rancher/k3s/server/manifests
      Unit=k3s-ready-dispatch.service

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, k3s-ready.path ]
```

### Hello World manifest
As a sanity check, you can drop a small hello-world app into `/etc/k3s-manifests/hello-world.yaml` so Traefik has something to route and you can confirm the API is alive. It bundles a namespace, deployment, service, and ingress in one file for boot-time install.

```
# /etc/k3s-manifests/hello-world.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: hello-world
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: hello-world
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
        - name: hello-world
          image: hashicorp/http-echo:latest
          args:
            - "-text=Hello, K3s!"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world-service
  namespace: hello-world
spec:
  selector:
    app: hello-world
  ports:
    - name: hello-world-80
      protocol: TCP
      port: 80
      targetPort: 5678
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress
  namespace: hello-world
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "false"
    kubernetes.io/ingress.class: "traefik"
spec:
  ingressClassName: traefik
  rules:
    - host: hello-world.kidd.network
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-world-service
                port:
                  number: 80
```

TODO Screenshot of hello world
![TODO](../../../../assets/todo.png)

## Next Steps

Now we're able to define the cluster and provision it automatically, but it's far from ideal. In our project the cluster nodes are backed by tmpfs, which Kubernetes is not designed to run on.

So next we will tweak some of the arguments during cluster creation to tune it a little
