---
title: Prerequisites
slug: guides/cluster-private-sso/prerequisites
description: What the cluster needs to look like before I started wiring up Dex, cert-manager, and trust-manager.
sidebar:
  order: 2
draft: false
---

Before going any further it's worth being honest about what this guide assumes is already in place. I built this on top of an existing setup, and some of the "prerequisites" are really just the previous guide's outputs.

:::tip[Coming in cold?]
If none of this is set up yet, the [Ephemeral K3s Cluster](./../../Ephemeral%20K3s%20Cluster/) guide gets you to the starting line. The Dex + CA bits below already happen automatically inside that flow — this guide is mostly explaining what was happening behind the curtain.
:::

## Cluster

- A running K3s cluster (single-node or HA, both fine).
- Traefik present as the Ingress controller. K3s ships it by default, which is half of why I picked K3s.
- Argo CD installed and pointed at this repo's `src/manifests/ainur` tree. It's the thing that actually deploys Dex, Headlamp and the cert portal.

If you followed [Multiple Nodes & Leader election](./../../Ephemeral%20K3s%20Cluster/deploying-k3s-on-netboot-nodes/) you already have all three.

## DNS

Internal hostnames need to resolve to the cluster Ingress. I run this on a flat home LAN with `dnsmasq` on the router pointing the `kidd.network` zone at my K3s node IPs. The names this guide cares about:

| Host | Served by |
|------|-----------|
| `dex.kidd.network` | Dex |
| `headlamp.kidd.network` | Headlamp |
| `argocd.kidd.network` | Argo CD |
| `cert.kidd.network` | CA download portal (optional) |

:::caution[Domain swap]
I've left `kidd.network` hardcoded throughout the manifests because it's a private lab and the convenience outweighs the parameterisation effort for me. If you're forking, swap it everywhere — values files, ingresses, Dex `issuer`, OIDC `redirectURIs`, the lot. There are 14+ occurrences and they all need to match or nothing trusts anything.
:::

## cert-manager and trust-manager

These get installed automatically by k3s' HelmChart controller via staged manifests from cloud-init:

- [user-data:589-606](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) — cert-manager HelmChart (`installCRDs: true`).
- [user-data:609-627](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) — trust-manager HelmChart.
- [user-data:629-640](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) — `ClusterIssuer local-ca` (waits for the runtime-created Secret).
- [user-data:642-663](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) — `Bundle lab-ca` (targets namespaces labelled `ainur.kidd.network/ca: inject`).

You don't have to apply these by hand. The cloud-init flow stages them into `/etc/k3s-manifests/` and k3s' HelmChart controller picks them up on boot.

## The Root CA Secret

There's one thing that's *not* in the repo: the Root CA key itself. `gen-lab-certs.sh` ([user-data:232-302](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data)) generates it once on the node and then materialises it as a Kubernetes Secret:

```bash
# excerpt from gen-lab-certs.sh
CA_CRT=/etc/rancher/k3s/oidc/lab-ca.crt
CA_KEY=/etc/k3s-certs/lab-ca.key
if [ ! -s "$CA_CRT" ] || [ ! -s "$CA_KEY" ]; then
  openssl genrsa -out "$CA_KEY" 4096
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -subj "/CN=Lab Root CA" -addext "basicConstraints=critical,CA:true" -out "$CA_CRT"
fi

# bind it into the cluster as cert-manager/cluster-root-ca
kubectl -n cert-manager create secret tls cluster-root-ca \
  --cert="$CA_CRT" --key="$CA_KEY" -o yaml --dry-run=client | kubectl apply -f -
```

The key never leaves the node. The Secret it produces is what the rest of the guide refers to as `cert-manager/cluster-root-ca` — you don't create it manually, it's just present.

## Access & Tooling

- `kubectl` admin access via `/etc/rancher/k3s/k3s.yaml`.
- A browser to test OIDC flows.
- An honest assessment of whether you trust the certs that are about to start showing up in your browser's history. If you mean to run any of this outside the LAN, ACME is a saner story than a local CA.

## Next Steps

[Configuring cert-manager for a Self-Signed CA](./configuring-cert-manager-self-signed-ca/) breaks down what those staged manifests actually do, in plain English, so the next time something breaks you know which knob to turn.
