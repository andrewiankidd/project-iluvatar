---
title: Setting Up Dex for OIDC
slug: guides/cluster-private-sso/setting-up-dex-for-oidc
description: Deploy Dex, configure clients and passwords, expose it over HTTPS, and prepare RBAC bindings.
sidebar:
  order: 3
draft: true
---

## Deploy via Argo CD

- Application: `src/manifests/ainur/dex.yml`
- Helm chart: `https://charts.dexidp.io` (version `0.19.0`)
- Destination namespace: `ainur-dex` (auto-created)

Argo CD will sync the Dex Helm chart using `values.yaml` and apply the additional Ingress/RBAC manifests in the same folder.

## Core Configuration

- Helm values: `src/manifests/ainur/dex/values.yaml`
  - `config.issuer`: `https://dex.kidd.network`
  - `staticPasswords`: demo admin user `admin@kidd.network` (bcrypt set for `ubuntu`; change in your environment)
  - `staticClients`:
    - `headlamp` with redirect `https://headlamp.kidd.network/oidc-callback`
    - `argocd` with redirect `https://argocd.kidd.network/auth/callback`

Example client entries:

```yaml
config:
  staticClients:
    - id: headlamp
      name: headlamp
      secret: dex-oidc-secret
      redirectURIs:
        - https://headlamp.kidd.network/oidc-callback
    - id: argocd
      name: argocd
      secret: dex-oidc-secret
      redirectURIs:
        - https://argocd.kidd.network/auth/callback
```

## HTTPS Exposure

- Ingress: `src/manifests/ainur/dex/ingress.yml`
- Annotations:
  - `kubernetes.io/ingress.class: "traefik"`
  - `cert-manager.io/cluster-issuer: "local-ca"`
- TLS secret: `dex-tls` for host `dex.kidd.network`.

Ensure `local-ca` ClusterIssuer exists before syncing the Ingress (see the cert-manager page).

## RBAC Mapping for Admin

- ClusterRoleBinding: `src/manifests/ainur/dex/rbac-admin-user.yml`
- Binds `admin@kidd.network` to `cluster-admin`. Adjust to your identities and roles.

## Secrets Hygiene

- Rotate `staticPasswords.hash` and `staticClients[].secret` for production.
- Consider external IdP connectors (e.g., GitHub, OIDC) instead of local password DB.
