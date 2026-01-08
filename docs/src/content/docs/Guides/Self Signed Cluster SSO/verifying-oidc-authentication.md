---
title: Verifying OIDC Authentication
slug: guides/cluster-private-sso/verifying-oidc-authentication
description: Test logins to Headlamp and Argo CD, validate TLS, and confirm RBAC mapping for users.
sidebar:
  order: 8
draft: true
---

## Trust the CA in Your Browser/OS

- Download and trust the CA from `https://cert.kidd.network/` (optional helper site).
- Alternatively, install `lab-ca.crt` into your OS trust store as documented in `src/manifests/ainur/cert/site.yml` content.

## Test Dex

- Visit `https://dex.kidd.network/` and confirm certificate is valid under your local CA.

## Headlamp Login

- Navigate to `https://headlamp.kidd.network/` and select OIDC login.
- Use your Dex user (e.g., `admin@kidd.network`) and verify you reach the UI.

## Argo CD Login

- Navigate to `https://argocd.kidd.network/` and use the OIDC flow.
- Confirm the RBAC policy maps your user to a suitable role (admin or otherwise).

## API OIDC (k3s)

- The bootstrap example appends API server flags for OIDC and CA file in `config.yaml`.
- With `kubectl` using OIDC, verify authentication and group claims are honored (optional).
