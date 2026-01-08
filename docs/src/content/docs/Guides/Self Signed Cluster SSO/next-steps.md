---
title: 'Summary & Next Steps'
slug: guides/cluster-private-sso/next-steps
description: Harden, extend, and operationalize your private SSO for production use.
sidebar:
  order: 11
draft: true
---

## Security Hardening

- Rotate Dex static passwords and client secrets; prefer external IdP connectors.
- Lock down Dex with connectors (LDAP, OIDC) and disable local password DB if not needed.
- Enforce strong RBAC policies for Argo CD and Kubernetes.

## Operational Maturity

- Automate CA rotation and re-issuance with planned maintenance windows.
- Backup CA materials stored outside the cluster (key escrow).
- Monitor cert-manager and Ingress certificate expiry.

## Extend SSO

- Add more OIDC clients (Grafana, Harbor, etc.).
- Enable API server OIDC for kubectl users and issue OIDC-backed kubeconfigs.
