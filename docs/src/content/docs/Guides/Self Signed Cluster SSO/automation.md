---
title: 'Summary & Next Steps'
slug: guides/cluster-private-sso/automation
description: "Cloud-init and Kubernetes manifests that automate the SSO stack: CA, cert-manager, trust-manager, Dex, Headlamp, Argo CD, and HTTPS."
sidebar:
  order: 10
draft: true
---

## Cloud-Init OIDC & CA (reference)

- File: `bootstrap/netboot/assets/ubuntuserver/boot/user-data.oidc.example` (also reflected in `user-data`).
- Generates a Root CA and stores at:
  - Cert: `/etc/rancher/k3s/oidc/lab-ca.crt`
  - Key: `/etc/k3s-certs/lab-ca.key`
- Creates `cert-manager/cluster-root-ca` secret and applies:
  - `ClusterIssuer local-ca` (CA backed)
  - trust-manager `Bundle` publishing `lab-ca` ConfigMap to labeled namespaces
- Configures k3s API OIDC flags with issuer URL `https://dex.kidd.network` and `oidc-ca-file` pointing to the CA.
- Optionally exposes the CA via a tiny NGINX site (`ainur-cert`) for easy browser install.

## Argo CD Bootstrap

- Staged manifest installs Argo CD and an app-of-apps to sync this repo:
  - `/etc/k3s-manifests/22-argocd-apps.helm.yaml`
- Adds an example Ingress for `argocd.kidd.network`.
- Argo CD OIDC is configured via values embedded in the same file:
  - `configs.cm.oidc.config` points at Dex; client secret injected via `configs.secret.extra`.

## Applications (src/manifests/ainur)

- Dex:
  - App: `src/manifests/ainur/dex.yml`
  - Values: `src/manifests/ainur/dex/values.yaml`
    - `issuer: https://dex.kidd.network`
    - `staticClients` for `headlamp` and `argocd` with matching redirect URIs
  - Ingress: `src/manifests/ainur/dex/ingress.yml` with `cert-manager.io/cluster-issuer: local-ca`
  - RBAC: `src/manifests/ainur/dex/rbac-admin-user.yml` mapping `admin@kidd.network` to cluster-admin
- Headlamp:
  - App: `src/manifests/ainur/headlamp.yml`
  - Values: `src/manifests/ainur/headlamp/values.yaml`
    - OIDC client fields and `SSL_CERT_DIR` + `lab-ca` mount for outbound TLS to Dex
  - Ingress: `src/manifests/ainur/headlamp/ingress.yml`
- CA Portal (optional): `src/manifests/ainur/cert/*` serves `lab-ca.crt` at `cert.kidd.network`.

## Result

Applying these manifests (via Argo CD) and cloud-init steps turns the guide into an automated, repeatable SSO rollout with consistent TLS and OIDC across cluster services.
