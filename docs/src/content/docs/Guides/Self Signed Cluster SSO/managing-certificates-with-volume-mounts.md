---
title: Managing Certificates with Volume Mounts
slug: guides/cluster-private-sso/managing-certificates-with-volume-mounts
description: Mount the trust bundle where apps expect OS trust and point clients at the injected CA.
sidebar:
  order: 6
draft: true
---

## Trust for Outbound TLS

Some apps validate TLS when calling other services (e.g., Headlamp contacting Dex). Mount the CA ConfigMap and point the app to it.

### Headlamp Example

From `src/manifests/ainur/headlamp/values.yaml`:

```yaml
env:
  - name: SSL_CERT_DIR
    value: /etc/ssl/local-ca
volumes:
  - name: local-ca
    configMap:
      name: lab-ca
      optional: true
volumeMounts:
  - name: local-ca
    mountPath: /etc/ssl/local-ca
    readOnly: true
```

### Argo CD Example (reference)

The bootstrap example applies the same pattern for `controller` and `repo-server` so they trust Helm repos and Git endpoints via the local CA. See `bootstrap/netboot/assets/ubuntuserver/boot/user-data.oidc.example` for full values.

## Namespace Labeling

Ensure target namespaces have `ainur.kidd.network/ca: inject` so trust-manager places the `lab-ca` ConfigMap automatically.
