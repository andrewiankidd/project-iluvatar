---
title: 'Summary & Next Steps'
slug: guides/cluster-private-sso/next-steps
description: What's still rough about this SSO setup, and where the project goes from here.
sidebar:
  order: 10
draft: false
---

I'm pretty happy with where this landed. The cluster has end-to-end TLS on internal hostnames, Headlamp and Argo CD share an identity, and adding a new OIDC-aware app is mostly "drop another `staticClients` entry into Dex and stand up an Ingress with the `local-ca` annotation".

That said, here's the honest list of "yeah I know" items.

## What's still rough

- **Argo CD's Ingress doesn't use cert-manager.** [user-data:867-891](../../../../../../bootstrap/netboot/assets/ubuntuserver/boot/user-data) wires the Argo CD Ingress with Traefik's default-cert TLS rather than a `lab-ca`-signed cert from cert-manager. Browsers that trust the lab CA still see a cert warning on `argocd.kidd.network`. Fixing this should be a one-annotation change to bring it in line with Dex and Headlamp.
- **Dex storage is in-memory.** Fine for static clients and static passwords from `values.yaml`, but if I add a GitHub or LDAP connector later that mints refresh tokens, those tokens evaporate on pod restart. The fix is to switch `storage.type` to `kubernetes` and let Dex use its CRDs.
- **Single static password in `values.yaml`.** It's a demo password (`ubuntu`) committed to git. Adequate for a private LAN; not adequate for anything else. The right move is either a connector (GitHub, GitLab, Authentik) or at least an envFrom-mounted Secret so the bcrypt hash isn't in the repo.
- **No automated CA rotation.** The CA is valid for 10 years (`-days 3650`). Long enough that I haven't built automation around rotation. If I were doing this at work I'd want cert-manager itself to rotate the CA on a schedule and re-publish trust through trust-manager.
- **k3s API OIDC is wired but I haven't lived in it.** It works for `--token` flows but I haven't built a `kubelogin`-driven kubeconfig that I actually use daily. So the auth-via-Dex story for kubectl is "demonstrably possible" rather than "battle-tested".
- **No groups end-to-end yet.** Dex emits groups, the API server is configured with `--oidc-groups-claim`, but the only RBAC binding I have is a per-user `ClusterRoleBinding`. Plumbing actual group-based RBAC ("members of `cluster-admins` get `cluster-admin`") is a small follow-up.

## Where this leads

The next chunk of the project is mostly about extending what's here:

- **Sidero Omni on Talos x86 nodes.** The Dex `staticClients` already has an `omni` entry waiting (see [Setting Up Dex](./setting-up-dex-for-oidc/#dex-values)). Once the x86/Talos guide is written, plumbing Omni as a Dex OIDC client should be a couple of lines on each side — Dex already knows about it, Omni just needs `--auth-saml-enabled` (or its OIDC equivalent) pointing at our issuer. The Omni team's [merged PR siderolabs/omni#1809](https://github.com/siderolabs/omni/pull/1809) made the Helm chart support custom OIDC issuer args; before that I was passing the flag through `extraArgs`.
- **External IdP.** I might wire Dex up to GitHub or an Authentik instance once I have more than one human user. The static-password story is fine for one person.
- **More apps as clients.** Adding Grafana, Loki, Harbor, or anything else with an OIDC option is a copy-paste of the Headlamp pattern.

## Recap

Over this guide set I:

- generated a Lab Root CA on the node and wired it into cert-manager as a `ClusterIssuer`,
- got trust-manager publishing the CA as a ConfigMap into the right namespaces *automatically*, by piggybacking on Argo CD's `managedNamespaceMetadata`,
- deployed Dex via a multi-source Argo CD Application with values, sibling manifests, and chart all separated,
- pointed Headlamp and Argo CD at Dex as OIDC clients, with `lab-ca` mounted as `SSL_CERT_DIR` so they trust outbound calls to Dex,
- and stood up a small CA-download portal so trusting the CA on a new laptop is a 30-second job.

It's been one of the more satisfying parts of the project to build because every piece slots neatly into the next, and the GitOps loop means "set up SSO" eventually became "the cluster has SSO when it boots".

[Back to the Guides index →](./../../)
