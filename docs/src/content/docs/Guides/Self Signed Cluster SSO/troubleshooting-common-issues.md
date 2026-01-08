---
title: Troubleshooting Common Issues
slug: guides/cluster-private-sso/troubleshooting-common-issues
description: Diagnose common pitfalls with OIDC, TLS, Ingress, DNS, and CA trust when using private SSO.
sidebar:
  order: 9
draft: true
---

## Dex Redirect Mismatch

- Ensure `redirectURIs` in Dex match exact URLs in Headlamp/Argo CD.
- Double-check trailing slashes and callback path casing.

## CA Not Trusted

- Import the CA into your OS/browser trust store.
- For pods making outbound TLS calls, mount the `lab-ca` ConfigMap and set `SSL_CERT_DIR`.

## Certificates Not Issuing

- Confirm cert-manager CRDs are installed and the controller is running.
- Verify `ClusterIssuer local-ca` exists and references `cert-manager/cluster-root-ca` with `tls.crt` and `tls.key`.
- Check Ingress annotations and `ingressClassName` match your controller.

## Ingress Not Routing

- Verify DNS resolves to the Ingress LoadBalancer/NodePort.
- Confirm Traefik is running and the Ingress resource is in the correct namespace.

## OIDC Login Fails

- Time skew between cluster and client can break OIDC; ensure NTP is healthy.
- Check Dex logs for client ID/secret mismatch or user auth errors.
- Inspect app config for `issuerURL`, `clientID`, and callback URL correctness.

## RBAC Denied After Login

- For Argo CD, verify `configs.rbac.policy.csv` maps your user/group.
- For Kubernetes API access, confirm OIDC `usernameClaim` and `groupsClaim` align with your RBAC.
