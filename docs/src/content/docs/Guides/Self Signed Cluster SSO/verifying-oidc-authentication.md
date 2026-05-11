---
title: Verifying OIDC Authentication
slug: guides/cluster-private-sso/verifying-oidc-authentication
description: End-to-end smoke tests for the SSO stack — CA trust, browser logins, RBAC, and (optionally) kubectl via OIDC.
sidebar:
  order: 7
draft: false
---

This is the "did it work?" pass. There's no point being clever earlier if you can't actually log in.

## Trust the CA locally

Before anything else, your browser and OS need to trust the lab Root CA. There's a small NGINX site that serves the CA with platform-specific install instructions — it's the friendliest way to do this on a new machine:

- Visit [`https://cert.kidd.network`](https://cert.kidd.network). (You'll get a cert warning on the *first* visit — that's expected, since you haven't trusted the CA yet. Bypass it once.)
- Download `lab-root-ca.crt` and follow the macOS / Windows / Linux instructions on the page.

Source for the portal lives at [src/manifests/ainur/cert/](../../../../../../src/manifests/ainur/cert) — the page itself is just a `ConfigMap` of styled HTML served by NGINX next to the CA file.

:::tip[Fingerprint check]
The page suggests verifying the cert with `sha256sum lab-root-ca.crt`. It's worth doing, because once you trust a CA your browser will accept anything it signs. Compare the value with the fingerprint of `/etc/rancher/k3s/oidc/lab-ca.crt` on the node:

```bash
ssh user@node 'sudo sha256sum /etc/rancher/k3s/oidc/lab-ca.crt'
```
:::

## Verify Dex

```bash
curl -s https://dex.kidd.network/.well-known/openid-configuration | jq .
```

You should get a chunk of JSON back with `issuer: "https://dex.kidd.network"` and a list of supported scopes. If `curl` reports a cert error, the OS-level trust store doesn't trust your CA — re-check the install instructions on the portal.

## Headlamp Login

1. Visit [`https://headlamp.kidd.network`](https://headlamp.kidd.network).
2. Click **Sign in with OIDC**. You should be bounced to Dex.
3. Log in with `admin@kidd.network` / `ubuntu` (or whatever you changed the password to — see [Setting Up Dex](./setting-up-dex-for-oidc/#dex-values)).
4. Dex redirects you to `https://headlamp.kidd.network/oidc-callback`, which should land you on the cluster overview.

If you get a logged-in *blank* state where Headlamp UI loads but every API call is "forbidden", you almost certainly don't have `useAccessToken: true` set in `values.yaml` — see the [Troubleshooting](./troubleshooting-common-issues/#headlamp-logs-in-but-cant-list-anything) page.

## Argo CD Login

1. Visit [`https://argocd.kidd.network`](https://argocd.kidd.network). (You may get a cert warning — Argo CD's Ingress uses Traefik's default cert, not `lab-ca`, see the [caveat in the previous page](./integrating-headlamp-and-argocd/#argo-cd-ingress).)
2. Click **Log in via Dex**.
3. Same Dex login as above.
4. You should land on the Argo CD UI as `admin@kidd.network`.

To confirm the RBAC mapping landed:

```bash
kubectl -n argocd get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}'
```

You should see `g, admin@kidd.network, role:admin`. If you log in and Argo says you can see nothing, the RBAC ConfigMap didn't pick up the value from the HelmChart's `configs.rbac.policy.csv` block — try `kubectl -n argocd rollout restart deploy argocd-server`.

## (Optional) kubectl via OIDC

`gen-lab-certs.sh` configures the k3s API server with OIDC flags so you can use Dex tokens directly with kubectl:

```bash
# excerpt — bootstrap/netboot/assets/ubuntuserver/boot/user-data:295-301
kube-apiserver-arg:
  - oidc-issuer-url=https://dex.kidd.network
  - oidc-client-id=headlamp
  - oidc-username-claim=email
  - oidc-groups-claim=groups
  - oidc-ca-file=/etc/rancher/k3s/oidc/lab-ca.crt
```

So once a user has a Dex-issued ID token, kubectl can present it via `--token` (or via the OIDC plugin if you're using something like `kubelogin`). The username the API server sees is whatever's in the `email` claim, which is exactly the string the `oidc-admin-admin-at-kidd-network` ClusterRoleBinding ([Setting Up Dex](./setting-up-dex-for-oidc/#admin-rbac)) binds to `cluster-admin`. Wire up a kubeconfig with a `users:` block that runs `kubectl oidc-login get-token …` and you have CLI access without a `k3s.yaml` admin token.

I haven't fully fleshed this out — it's been "good enough that I can prove it works" rather than a daily-driver setup. Worth coming back to.

## End-to-End Verification

If you got here without anything erroring, the SSO stack is doing its job:

- ✅ Browser trusts the lab CA (one-time setup per machine)
- ✅ Dex's HTTPS endpoint serves a lab-CA-signed cert
- ✅ Headlamp redirects to Dex, accepts the token, lists resources
- ✅ Argo CD redirects to Dex, accepts the token, you can see Applications
- ✅ k3s API server accepts OIDC tokens (optional)

## Next Steps

When (not if) something doesn't work, [Troubleshooting](./troubleshooting-common-issues/) is the next place to look. Otherwise: [Automation & How It Fits Together](./automation/) for the bird's-eye GitOps view, or [Next Steps](./next-steps/) for what I'd still like to clean up.
