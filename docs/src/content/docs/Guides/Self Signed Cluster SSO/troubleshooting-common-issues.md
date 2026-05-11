---
title: Troubleshooting Common Issues
slug: guides/cluster-private-sso/troubleshooting-common-issues
description: The footguns I actually hit while wiring all of this up — bcrypt quoting, useAccessToken, time skew, and the order Argo CD reconciles things.
sidebar:
  order: 8
draft: false
---

These are the issues that ate hours of my evenings, in roughly the order I hit them. None of them are exotic; all of them are obvious in hindsight.

:::caution[Memory disclaimer]
I'm reconstructing some of this from memory after a break from the project, so it's possible a couple of these were transient and have since been fixed in the upstream charts. If you hit one and the symptom doesn't quite match — open an issue with what you saw.
:::

## "Invalid bcrypt hash" from Dex

**Symptom:** Dex pod starts, logs `error parsing password hash` or `bcrypt: hashedSecret too short`, then exits or refuses logins.

**Cause:** `htpasswd -nbBC 10 "" 'pass'` produces output like `:$2y$10$abc…\n`. Pasted as-is into `staticPasswords[].hash` in `values.yaml`, the leading colon and trailing newline make the string an invalid bcrypt hash. YAML happily accepts it, Dex doesn't.

**Fix:** Always strip them:

```bash
htpasswd -nbBC 10 "" 'YourStrongPass' | tr -d ':\n'
```

Comment in [src/manifests/ainur/dex/values.yaml:9](../../../../../../src/manifests/ainur/dex/values.yaml) shows the canonical form. If you pre-quoted the YAML value, remember that `$` inside double quotes might trigger envsubst in some chart wrappers — keep it inside single quotes or unquoted.

## Headlamp logs in but can't list anything

**Symptom:** Headlamp shows you the cluster overview, but every resource list says "forbidden" or just stays empty. The browser has a session, the URL bar is happy.

**Cause:** Headlamp is validating the **ID token** with Dex but presenting nothing useful to the Kubernetes API server. Newer Headlamp versions need to present the access token to the API.

**Fix:** Add `useAccessToken: true` under `config.oidc` in [headlamp/values.yaml:16](../../../../../../src/manifests/ainur/headlamp/values.yaml). It's already set in the live values, but if you're following along on a fork and missed it this is the symptom.

## Trust bundle not landing in a namespace

**Symptom:** A pod is crashlooping with `unknown authority`-style TLS errors when it talks to Dex. `kubectl get cm lab-ca -n <namespace>` returns nothing.

**Cause:** Either the namespace doesn't have the `ainur.kidd.network/ca: inject` label, or trust-manager isn't reconciling.

**Fix in order of likelihood:**

1. Check the label is present:
   ```bash
   kubectl get ns <namespace> --show-labels | grep 'ainur.kidd.network/ca'
   ```
   If missing and the namespace is managed by an Argo CD `Application`, force-sync the app — `managedNamespaceMetadata` reapplies on sync. If the namespace was created by a HelmChart (like `argocd`), the label has to be baked into the `Namespace` YAML directly.

2. Confirm trust-manager is up:
   ```bash
   kubectl -n cert-manager get pods -l app=trust-manager
   kubectl -n cert-manager logs deploy/trust-manager
   ```

3. Inspect the Bundle's status:
   ```bash
   kubectl get bundle lab-ca -o yaml | yq .status
   ```
   `Synced: True` should be present in the conditions. If it says the source Secret is missing, `gen-lab-certs.sh` didn't run or didn't create `cert-manager/cluster-root-ca`.

## "x509: certificate signed by unknown authority" from in-cluster pods

**Symptom:** A pod can `curl http://dex.kidd.network/.well-known/openid-configuration` fine, but `https://` fails with x509.

**Cause:** The pod's image doesn't trust the lab CA. The `lab-ca` ConfigMap is in the namespace, but the pod doesn't mount it.

**Fix:** Add the standard mount block to the pod spec:

```yaml
env:
  - name: SSL_CERT_DIR
    value: /etc/ssl/local-ca
volumes:
  - name: lab-ca
    configMap:
      name: lab-ca
      optional: true
volumeMounts:
  - name: lab-ca
    mountPath: /etc/ssl/local-ca
    readOnly: true
```

If the app is a Helm chart, look for an `extraVolumes` / `extraEnv` values key. If it's a stubbornly-built image that hardcodes its CA path elsewhere, you may need to mount the cert at the path the binary actually reads.

## OIDC login bounces, browser shows "invalid_token"

**Symptom:** Dex hands back a token, the app accepts the redirect, then loops or fails with token validation.

**Cause:** Almost always clock skew. OIDC tokens have a `nbf` (not-before) and `exp` (expiry) and a few seconds of skew between Dex's clock and the verifying app's clock is enough to reject every freshly-issued token.

**Fix:** Make sure NTP is healthy on every node:

```bash
timedatectl status
```

You want `System clock synchronized: yes` and `NTP service: active`. On the netboot Pis this can drift if `systemd-timesyncd` doesn't find a server quickly. Set `runcmd` in cloud-init to enable timesyncd and/or wire `chrony`.

## Argo CD says "OIDC config not found" or "no valid client found"

**Symptom:** Argo CD UI's "Log in via OIDC" button is missing, or clicking it errors immediately.

**Cause:** The `argocd-cm` ConfigMap doesn't have an `oidc.config` key, or `argocd-secret` doesn't have the `oidc.dex.clientSecret` extra.

**Fix:** Both come from [user-data:760-780](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) (the `configs.cm` and `configs.secret.extra` blocks of the Argo CD HelmChart). If you've edited values and lost them, redeploying the HelmChart will restore them. If you've modified `argocd-cm` directly, your changes survive a HelmChart re-sync only because `helm.cattle.io` reconciles non-destructively — but a fresh boot will overwrite them.

## "invalid_redirect_uri" from Dex

**Symptom:** Login fails before any password prompt; Dex error page says the redirect URI doesn't match a registered client.

**Cause:** The `redirectURIs` list in `staticClients` (Dex values.yaml) must contain the exact URL the app sends, including the path, trailing slash, scheme. Headlamp posts to `/oidc-callback`; Argo CD posts to `/auth/callback`. Don't trim.

**Fix:** Compare:

```bash
kubectl -n ainur-dex get cm dex -o jsonpath='{.data.config\.yaml}' | grep -A2 redirectURIs
```

against what the browser is actually sending (DevTools → Network → look at the redirect URL).

## Argo CD's `dex.argocd.io` errors

**Symptom:** Argo CD logs mention trying to start its own bundled Dex, or there's a `dex-server` pod in the `argocd` namespace failing to schedule.

**Cause:** The Argo CD chart bundles a Dex by default. We disabled it via `dex.enabled: false` in the HelmChart values ([user-data:713-714](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data)), but if that toggle gets lost during upgrades you'll have two Dexes fighting.

**Fix:** Re-check `dex.enabled: false` is still in the values. The pod should not exist in `argocd`.

## The trust-bundle Bundle shows "Synced: False"

**Symptom:** `kubectl get bundle lab-ca` says `False` under SYNCED.

**Cause:** Usually the source Secret is missing. trust-manager wants `cert-manager/cluster-root-ca` and its `tls.crt` key specifically.

**Fix:**
```bash
kubectl -n cert-manager get secret cluster-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | head -1
```
You should see `-----BEGIN CERTIFICATE-----`. If the Secret is missing, re-run `gen-lab-certs.sh` on the node, or reboot to let cloud-init redo it. If the Secret exists but the cert key is wrong, the most common cause is that the `--cert` and `--key` paths weren't readable when `gen-lab-certs.sh` ran (race with NVMe mount, etc).

## Next Steps

If you've worked through all of these and something *still* isn't right, the [Automation page](./automation/) has the bigger picture of how the GitOps chain assembles itself — sometimes the symptom is downstream of an Argo CD sync wave problem rather than the SSO config itself.
