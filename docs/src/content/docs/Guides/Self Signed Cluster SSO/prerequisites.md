---
title: Prerequisites
slug: guides/cluster-private-sso/prerequisites
description: Requirements and environment assumptions before enabling private SSO with Dex and a local CA.
sidebar:
  order: 2
draft: true
---

## Cluster & DNS

- A running Kubernetes cluster with an Ingress controller (Traefik).
- Internal DNS records pointing at the Ingress for:
  - `dex.kidd.network`
  - `headlamp.kidd.network`
  - `argocd.kidd.network`
  - Optional CA portal: `cert.kidd.network`
- Replace `kidd.network` with your domain where applicable.

## Cert-Manager & Trust-Manager

- cert-manager installed with CRDs available.
- trust-manager installed with CRDs available.
- A CA Secret for the issuer, e.g. `cert-manager/cluster-root-ca` holding your CA keypair.

## Argo CD (Optional but Recommended)

- Argo CD installed and managing applications under a project (e.g., `ainur`).
- Ability to sync the applications under `src/manifests/ainur`.

## Access & Tooling

- `kubectl` access to the cluster with admin rights.
- Ability to create DNS records and open local browser access to the above hostnames.
