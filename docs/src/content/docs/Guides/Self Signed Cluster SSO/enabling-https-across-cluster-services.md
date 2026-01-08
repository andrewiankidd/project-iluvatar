---
title: Enabling HTTPS Across Cluster Services
slug: guides/cluster-private-sso/enabling-https-across-cluster-services
description: Issue TLS via cert-manager’s local CA and ensure Ingress routes use HTTPS with trusted certificates.
sidebar:
  order: 7
draft: true
---

## Dex

- Ingress: `src/manifests/ainur/dex/ingress.yml`
- Annotations:
  - `kubernetes.io/ingress.class: "traefik"`
  - `cert-manager.io/cluster-issuer: "local-ca"`
- TLS:
  - `hosts: [dex.kidd.network]`
  - `secretName: dex-tls`

## Headlamp

- Ingress: `src/manifests/ainur/headlamp/ingress.yml`
- Annotations and TLS configured similarly for `headlamp.kidd.network`.

## Argo CD

- Example Ingress exists in `user-data.oidc.example` for `argocd.kidd.network`.
- Ensure TLS is enabled and, if using cert-manager, annotate with `cert-manager.io/cluster-issuer: "local-ca"` and set a `secretName`.

## Optional: CA Download Portal

- Simple NGINX site to serve the CA for browser trust: `src/manifests/ainur/cert/*`.
- Ingress at `cert.kidd.network` with TLS from `local-ca`.
