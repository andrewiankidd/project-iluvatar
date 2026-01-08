---
title: Integrating Headlamp and Argo CD
slug: guides/cluster-private-sso/integrating-headlamp-and-argocd
description: Configure Headlamp and Argo CD as Dex OIDC clients with proper redirect URIs, scopes, and TLS trust.
sidebar:
  order: 4
draft: true
---

## Headlamp OIDC

- Values: `src/manifests/ainur/headlamp/values.yaml`
  - `config.oidc.issuerURL`: `https://dex.kidd.network`
  - `config.oidc.clientID`: `headlamp`
  - `config.oidc.clientSecret`: `dex-oidc-secret`
  - `config.oidc.callbackURL`: `https://headlamp.kidd.network/oidc-callback`
  - `config.oidc.scopes`: `openid profile email`

TLS trust for outbound calls to Dex is provided by mounting the `lab-ca` ConfigMap and pointing `SSL_CERT_DIR` to it:

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

- Ingress: `src/manifests/ainur/headlamp/ingress.yml` with `cert-manager.io/cluster-issuer: "local-ca"`.

## Argo CD OIDC

If bootstrapping via cloud-init, see `bootstrap/netboot/assets/ubuntuserver/boot/user-data.oidc.example` for in-cluster configuration of OIDC and TLS trust. Key parts:

- Argo CD ConfigMap OIDC section:

```yaml
configs:
  cm:
    oidc.config: |
      name: Dex
      issuer: https://dex.kidd.network
      clientID: argocd
      clientSecret: $oidc.dex.clientSecret
      usernameClaim: email
      groupsClaim: groups
      requestedScopes:
        - openid
        - profile
        - email
  secret:
    extra:
      oidc.dex.clientSecret: dex-oidc-secret
```

- Optional Ingress for Argo CD server at `argocd.kidd.network` (example in the same user-data file).
- RBAC example (map your admin email to `role:admin`):

```yaml
configs:
  rbac:
    policy.csv: |
      g, admin@kidd.network, role:admin
    scopes: '[groups, email]'
```

Ensure Dex has an `argocd` client with the matching redirect URI and secret.
