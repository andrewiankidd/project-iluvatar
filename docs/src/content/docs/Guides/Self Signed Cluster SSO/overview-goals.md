---
title: Overview & Goals
slug: guides/cluster-private-sso
description: Unify authentication across cluster services using Dex (OIDC), a self-signed CA, cert-manager/trust-manager, and Ingress.
sidebar:
  order: 1
draft: true
---

## What You'll Build

- A private Single Sign-On stack backed by Dex (OIDC provider).
- A cluster-trusted self-signed Root CA to terminate HTTPS on internal hostnames.
- cert-manager with a ClusterIssuer that signs service certificates using your CA.
- trust-manager that injects a trusted CA ConfigMap into labeled namespaces.
- OIDC-enabled logins for Headlamp and Argo CD using the same Dex identity.

## Why a Private SSO

- One identity to access multiple cluster apps (Headlamp, Argo CD, etc.).
- End-to-end TLS with a local CA; no public internet required.
- Clear separation of identity (Dex), authorization (RBAC), and transport (TLS).

## Components

- Dex Helm chart and Ingress at `dex.kidd.network`.
- cert-manager ClusterIssuer `local-ca` issuing TLS certs for internal FQDNs.
- trust-manager Bundle published as ConfigMap `lab-ca` to labeled namespaces.
- Headlamp and Argo CD configured as OIDC clients of Dex.
- Traefik as the Ingress controller with TLS from cert-manager.

## Related Manifests

- Dex Argo CD app: `src/manifests/ainur/dex.yml`
- Dex Helm values: `src/manifests/ainur/dex/values.yaml`
- Dex Ingress: `src/manifests/ainur/dex/ingress.yml`
- Headlamp Argo CD app: `src/manifests/ainur/headlamp.yml`
- Headlamp values: `src/manifests/ainur/headlamp/values.yaml`
- Headlamp Ingress: `src/manifests/ainur/headlamp/ingress.yml`
- CA download site (optional): `src/manifests/ainur/cert/*`
- Cloud-init OIDC/CA bootstrap reference: `bootstrap/netboot/assets/ubuntuserver/boot/user-data`

## Flow at a Glance

1) Generate a Root CA and install cert-manager/trust-manager with a CA ClusterIssuer.
2) Deploy Dex with a public HTTPS endpoint on your internal DNS.
3) Configure Headlamp and Argo CD as Dex clients with redirect URIs.
4) Issue TLS certs to Dex/Headlamp/Argo CD via `local-ca` and enable HTTPS.
5) Mount the CA ConfigMap in apps that make outbound TLS calls (as needed).
