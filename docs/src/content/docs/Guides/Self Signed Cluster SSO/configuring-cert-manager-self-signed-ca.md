---
title: Configuring cert-manager for Self-Signed CA
slug: guides/cluster-private-sso/configuring-cert-manager-self-signed-ca
description: Create a ClusterIssuer backed by your local CA and publish trust to namespaces with trust-manager.
sidebar:
  order: 5
draft: true
---

## Create or Reuse a Root CA

- Generate and persist a Root CA on the node(s) (see `user-data`):
  - Cert path: `/etc/rancher/k3s/oidc/lab-ca.crt`
  - Key path: `/etc/k3s-certs/lab-ca.key`

## Import CA into cert-manager

- Create a TLS Secret used by the CA issuer:

```bash
kubectl -n cert-manager create secret tls cluster-root-ca \
  --cert=/etc/rancher/k3s/oidc/lab-ca.crt \
  --key=/etc/k3s-certs/lab-ca.key
```

## Define the ClusterIssuer

Example (from `user-data.oidc.example`):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca
spec:
  ca:
    secretName: cluster-root-ca
```

Apply after cert-manager CRDs are present.

## Distribute Trust with trust-manager

Create a `Bundle` that injects a ConfigMap named `lab-ca` into labeled namespaces (e.g., `ainur.kidd.network/ca=inject`):

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: lab-ca
spec:
  sources:
    - secret:
        name: cluster-root-ca
        key: tls.crt
        namespace: cert-manager
  target:
    configMap:
      key: ca.crt
    namespaceSelector:
      matchLabels:
        ainur.kidd.network/ca: inject
```

Apps can now mount `lab-ca` to trust the local CA for outbound TLS.
