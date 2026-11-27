---
title: Setting Up Dex for OIDC
slug: guides/cluster-private-sso/setting-up-dex-for-oidc
description: Deploy Dex via Argo CD, configure static clients for Headlamp and Argo CD, expose it on HTTPS using the cluster CA.
sidebar:
  order: 4
draft: false
---

Dex is the simplest OIDC provider I've found, and it's perfect for a lab — it can run with an in-memory store and a literal YAML list of users while still speaking the protocol every cluster app expects.

## Explanation

I'm deploying Dex via Argo CD using a slightly unusual pattern: the Application has **three** sources. One is the upstream Helm chart, one is this repo's directory for sibling manifests (Ingress, RBAC), and one is the same repo registered as a `$values` reference so Helm can pull `values.yaml` out of git.

That third source is the bit that surprised me when I first wrote it — without it you can't tell Helm "the values file is in another repo entirely". It's a multi-source App, which is a relatively new Argo CD feature.

Dex stores nothing on disk. The static client list and a single demo password live in `values.yaml`, the Ingress lives next door, the cluster-admin RBAC binding sits in the same folder, and Argo CD reconciles the whole lot.

## Implementation

### The Argo CD Application

```yaml
# src/manifests/ainur/dex.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dex
  namespace: ainur
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: ainur
  sources:
    - repoURL: https://charts.dexidp.io
      targetRevision: 0.19.0
      chart: dex
      helm:
        valueFiles:
          - $values/src/manifests/ainur/dex/values.yaml
    - repoURL: https://github.com/andrewiankidd/project-iluvatar.git
      targetRevision: main
      path: src/manifests/ainur/dex
    - repoURL: https://github.com/andrewiankidd/project-iluvatar.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ainur-dex
  syncPolicy:
    managedNamespaceMetadata:
      labels:
        ainur.kidd.network/ca: inject
    syncOptions:
      - CreateNamespace=true
    automated:
      prune: true
      selfHeal: true
```

Things worth pointing out:

- **`sync-wave: "-1"`** — Dex syncs *before* other apps that depend on it. The cluster-admin RBAC binding (`rbac-admin-user.yml`) is annotated with `sync-wave: "2"` so it lands once the namespace and Dex are settled.
- **`managedNamespaceMetadata.labels`** — Argo CD writes `ainur.kidd.network/ca: inject` onto the `ainur-dex` namespace on every sync. That's what causes trust-manager to drop a `lab-ca` ConfigMap into the namespace.
- **The third source (`ref: values`)** — exists purely so the Helm source can read `$values/src/manifests/ainur/dex/values.yaml`. Without it Argo CD doesn't know where `$values` points.

### Dex values

```yaml
# src/manifests/ainur/dex/values.yaml
config:
  issuer: https://dex.kidd.network
  storage:
    type: memory
  enablePasswordDB: true
  staticPasswords:
    - email: admin@kidd.network
      # bcrypt of a demo password: change for your environment
      # generate with: htpasswd -nbBC 10 "" 'YourStrongPass' | tr -d ':\n'
      # Password: ubuntu
      hash: $2y$10$66R20C4j0E4d0tjg7YewX.b7UvI3XoA6CcxAFO7Pj8J6izWLY18S6
      username: admin
      userID: "0001"
  staticClients:
    - id: headlamp
      name: headlamp
      secret: <your-client-secret>
      redirectURIs:
        - https://headlamp.kidd.network/oidc-callback
    - id: argocd
      name: argocd
      secret: <your-client-secret>
      redirectURIs:
        - https://argocd.kidd.network/auth/callback

service:
  type: ClusterIP
```

The hash above is the guide's example. The lab itself keeps no hash in git: `hashFromEnv: AINUR_DEX_ADMIN_HASH` reads it from the `ainur-secrets` Secret, made from the bootstrap `.env`, and `bootstrap/netboot/scripts/set-admin-password.sh` sets it (see [the `.env` reference](../../reference/env/)).

A few notes from things I learned the hard way:

:::caution[storage.type: memory]
Dex's in-memory storage is fine for static clients and static passwords, but anything dynamic (e.g. OIDC connectors that issue refresh tokens) is lost on pod restart. For a lab whose password list is static anyway this is a feature, not a bug — but if you bolt on a GitHub connector later, plan for `storage.type: kubernetes` and the CRDs that come with it.
:::

:::tip[Regenerating the bcrypt hash]
The comment in `values.yaml` shows the canonical one-liner: `htpasswd -nbBC 10 "" 'YourStrongPass' | tr -d ':\n'`. The bcrypt cost (`10`) is fine for the lab. If you're tempted to skip the `tr -d ':\n'` — don't. `htpasswd` emits a leading colon and trailing newline that Dex won't accept, and you'll spend an hour wondering why a perfectly valid bcrypt string is being rejected.
:::

:::tip[There's an `omni` static client too]
If you check the live `values.yaml` you'll spot a third `staticClients` entry for `omni`. It's wired up in advance of the [x86 / Talos work](../../../../Architecture/x86/) — Sidero Omni speaks OIDC and Dex will be its identity provider once that section is fleshed out. Ignore it until then; the client config is harmless on its own.
:::

### Ingress

```yaml
# src/manifests/ainur/dex/ingress.yml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dex-ingress
  namespace: ainur-dex
  annotations:
    kubernetes.io/ingress.class: "traefik"
    cert-manager.io/cluster-issuer: "local-ca"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - dex.kidd.network
      secretName: dex-tls
  rules:
    - host: dex.kidd.network
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: dex
                port:
                  number: 5556
```

The `cert-manager.io/cluster-issuer: local-ca` annotation is what tells cert-manager "issue a cert for `dex.kidd.network` from the `local-ca` ClusterIssuer and stash it in the `dex-tls` Secret". The Ingress then serves that on the way through.

### Admin RBAC

```yaml
# src/manifests/ainur/dex/rbac-admin-user.yml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-admin-admin-at-kidd-network
  annotations:
    argocd.argoproj.io/sync-wave: "2"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: admin@kidd.network
```

When k3s' API server is started with `--oidc-username-claim=email` (which `gen-lab-certs.sh` configures — see [user-data:292-301](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data)), the username string presented by Dex is literally the email. So this `ClusterRoleBinding` says "the OIDC user `admin@kidd.network` is cluster-admin". `sync-wave: "2"` makes sure the ClusterRoleBinding doesn't get applied before the namespace exists.

## What you should see after this lands

```text
$ kubectl -n ainur-dex get pods
NAME                   READY   STATUS    RESTARTS   AGE
dex-7f4b9d8c4f-x6sk2   1/1     Running   0          1d

$ kubectl -n ainur-dex get ingress
NAME          CLASS    HOSTS              ADDRESS        PORTS     AGE
dex-ingress   traefik  dex.kidd.network   192.168.1.x    80, 443   1d

$ curl -s https://dex.kidd.network/.well-known/openid-configuration | jq .issuer
"https://dex.kidd.network"
```

If that `curl` returns a cert error, your CA isn't trusted on the machine you're running it from. See [Verifying OIDC Authentication](./verifying-oidc-authentication/#trust-the-ca-locally).

## Next Steps

Dex is up. Next we point Headlamp and Argo CD at it: [Integrating Headlamp and Argo CD](./integrating-headlamp-and-argocd/).
