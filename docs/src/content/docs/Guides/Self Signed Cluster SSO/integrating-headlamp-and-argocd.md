---
title: Integrating Headlamp and Argo CD
slug: guides/cluster-private-sso/integrating-headlamp-and-argocd
description: Point Headlamp and Argo CD at Dex, mount the lab CA so outbound TLS calls verify, and map identities to RBAC.
sidebar:
  order: 5
draft: false
---

Dex is up, so the next thing is to teach the two UIs I actually use — Headlamp and Argo CD — to log people in through it. They're configured very differently: Headlamp is a normal Argo CD-managed app under `src/manifests/ainur/`, while Argo CD is **its own** OIDC client and gets configured during the cloud-init bootstrap (because by the time it's syncing other things, it's already deployed itself).

## Explanation

Both apps have to do two distinct things to talk to Dex:

1. **OIDC client config.** Tell the app where Dex lives, what client ID and secret to use, and where Dex should redirect users on successful login.
2. **Trust Dex's certificate when making *outbound* TLS calls.** Dex's cert is signed by the lab CA, which the OS image doesn't trust by default. Mounting the `lab-ca` ConfigMap and pointing `SSL_CERT_DIR` at it solves this without baking the CA into the container image.

The redirect URI in Dex's `staticClients` and the callback URL configured in the app **must match exactly**. If you've ever debugged "invalid redirect_uri" loops, it's almost always because one has a trailing slash and the other doesn't.

## Headlamp OIDC

### Application

```yaml
# src/manifests/ainur/headlamp.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: headlamp
  namespace: ainur
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: ainur
  sources:
    - repoURL: https://kubernetes-sigs.github.io/headlamp/
      targetRevision: 0.36.0
      chart: headlamp
      helm:
        valueFiles:
          - $values/src/manifests/ainur/headlamp/values.yaml
    - repoURL: https://github.com/andrewiankidd/project-iluvatar.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/andrewiankidd/project-iluvatar.git
      targetRevision: main
      path: src/manifests/ainur/headlamp
  destination:
    server: https://kubernetes.default.svc
    namespace: ainur-headlamp
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    managedNamespaceMetadata:
      labels:
        ainur.kidd.network/ca: inject
    automated:
      prune: true
      selfHeal: true
```

Same three-source pattern as Dex, same `managedNamespaceMetadata` trick for the CA bundle.

### Values

```yaml
# src/manifests/ainur/headlamp/values.yaml
serviceAccount:
  create: true
  name: headlamp

rbac:
  create: true

config:
  inCluster: true
  oidc:
    clientID: "headlamp"
    clientSecret: "<your-client-secret>"
    issuerURL: "https://dex.kidd.network"
    scopes: "openid profile email"
    callbackURL: "https://headlamp.kidd.network/oidc-callback"
    useAccessToken: true

env:
  - name: SSL_CERT_DIR
    value: /etc/ssl/local-ca
volumes:
  - name: local-ca
    configMap:
      name: lab-ca
      optional: true
volumeMounts:
  - name: local-ca
    mountPath: /etc/ssl/local-ca
    readOnly: true
clusterRoleBinding:
  create: false
```

Two non-obvious things in here:

- **`useAccessToken: true`** — Headlamp by default validates the ID token against Dex on every request. Newer Headlamp versions also need the access token presented to the API server. If you skip this you can get into a state where login succeeds (Dex redirects, browser stores a token) but every kubectl-style action in the UI bombs with an auth error. Took me an evening to track down.
- **`optional: true` on the configMap volume** — until trust-manager has actually written the `lab-ca` ConfigMap into the `ainur-headlamp` namespace, the volume mount would fail and the pod would crashloop. `optional: true` makes the mount tolerant of a missing ConfigMap, which is fine because `SSL_CERT_DIR` will just fall back to the empty mount until trust-manager catches up.

### Ingress

```yaml
# src/manifests/ainur/headlamp/ingress.yml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp-ingress
  namespace: ainur-headlamp
  annotations:
    kubernetes.io/ingress.class: "traefik"
    cert-manager.io/cluster-issuer: "local-ca"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - headlamp.kidd.network
      secretName: headlamp-tls
  rules:
    - host: headlamp.kidd.network
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: headlamp
                port:
                  number: 80
```

Same `cert-manager.io/cluster-issuer: local-ca` annotation as Dex — cert-manager produces `headlamp-tls`, Traefik serves it.

## Argo CD OIDC

Here's the twist: Argo CD configures itself for OIDC during the cluster bootstrap, not via an Argo CD Application. There's a chicken-and-egg reason — by the time Argo CD is syncing apps from this repo, it's already deployed and needs to know how to authenticate the user clicking "Sign in via Dex".

So the OIDC wiring lives in the same cloud-init HelmChart that installs Argo CD in the first place.

```yaml
# /etc/k3s-manifests/21-argocd.helm.yaml — bootstrap/netboot/assets/ubuntuserver/boot/user-data:687-781
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    ainur.kidd.network/ca: inject   # so trust-manager publishes lab-ca here
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  chart: argo-cd
  repo: https://argoproj.github.io/argo-helm
  targetNamespace: argocd
  createNamespace: true
  valuesContent: |
    global:
      domain: argocd.kidd.network
    dex:
      enabled: false                # don't run Argo's bundled Dex; we have our own
    server:
      extraArgs:
        - --insecure                # Traefik terminates TLS in front of us
      # Trust the lab CA for outbound TLS to Dex
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
    repoServer:
      # same SSL_CERT_DIR / lab-ca volume mount — so the repo-server trusts
      # internal Helm/Git repos that are signed by the lab CA.
      ...
    configs:
      cm:
        oidc.config: |
          name: Dex
          issuer: https://dex.kidd.network
          clientID: argocd
          clientSecret: $oidc.dex.clientSecret
          usernameClaim: email
          groupsClaim: groups
          requestedScopes:
            - openid
            - profile
            - email
      rbac:
        policy.csv: |
          g, admin@kidd.network, role:admin
        scopes: '[groups, email]'
      secret:
        extra:
          oidc.dex.clientSecret: <your-client-secret>
```

The bits that took me a minute to internalise:

- **`dex.enabled: false`** — Argo CD's Helm chart bundles a Dex of its own. That Dex would conflict with the one we just deployed, so we disable the bundled one.
- **`server.extraArgs: --insecure`** — Argo CD runs HTTP internally and lets Traefik terminate TLS. The `--insecure` here means "don't try to run TLS on the server itself", not "no security". Without it, Argo serves HTTPS internally and Traefik's reverse proxy hits TLS issues.
- **`$oidc.dex.clientSecret`** — Argo CD substitutes any `$reference` in `oidc.config` with values from the `argocd-secret` Secret. So the actual client secret lives in `configs.secret.extra.oidc.dex.clientSecret` and Argo wires them together.
- **The namespace label** — written directly on the namespace by the HelmChart, not via Argo's `managedNamespaceMetadata` (because Argo CD is its own deployer here). Same effect: trust-manager publishes `lab-ca` into `argocd`, and the volume mounts above resolve.

### Argo CD Ingress

```yaml
# /etc/k3s-manifests/23-argocd-ingress.yaml — bootstrap/netboot/assets/ubuntuserver/boot/user-data:867-891
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"
    kubernetes.io/ingress.class: traefik
spec:
  ingressClassName: traefik
  rules:
    - host: argocd.kidd.network
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

:::caution[Argo CD Ingress doesn't use the lab CA]
Note this Ingress has no `cert-manager.io/cluster-issuer` annotation and no `tls:` block. It enables TLS via Traefik's `router.tls: "true"` annotation, which means Traefik serves it using its own default certificate — not a `lab-ca`-signed one. Browsers that trust the lab CA will still see a cert warning on `argocd.kidd.network` unless you also trust Traefik's default cert or wire up a `cert-manager`-issued cert here. This was deferred when I built it; an item for the [next-steps](./next-steps/) list.
:::

## What you should see after this lands

```text
$ kubectl -n ainur-headlamp get cm lab-ca -o yaml | head -5
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-ca
  namespace: ainur-headlamp

$ kubectl -n argocd get cm lab-ca -o yaml | head -5
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-ca
  namespace: argocd
```

Visit [`https://headlamp.kidd.network`](https://headlamp.kidd.network) and you should be redirected to Dex, log in with `admin@kidd.network` and the admin password, then bounced back to a logged-in Headlamp.

## Next Steps

Two things both apps needed in common: the `lab-ca` ConfigMap and `SSL_CERT_DIR` pointing at it. The next page explains how that ConfigMap lands in the right namespaces *without* a single manual `kubectl label` — [Managing certificates with volume mounts](./managing-certificates-with-volume-mounts/).
