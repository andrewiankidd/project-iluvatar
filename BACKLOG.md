# project-iluvatar — Backlog

Honest internal tracking of gaps, debt, and "would be nice" items that don't belong in the user-facing docs. Reviewed conversationally on 2026-05-12.

The project's intended scope is **a single-site, LAN-trusted personal homelab cloud** for hobby workloads (Minecraft, etc.) plus a k8s/Argo CD sandbox. The list below is graded against that scope, not against a production-grade deployment.

## What's currently good

- Self-reproducing bootstrap loop (ouroboros). The cluster hosts the netboot stack that boots the cluster.
- Everything declarative from cloud-init → k3s HelmChart manifests → Argo CD app-of-apps. Almost no imperative state.
- Honest separation of "stateless ephemeral nodes" from "stateful cluster" via Longhorn + selectable persistence.
- SSO + private CA chain auto-wires across apps with zero manual `kubectl label` steps.
- The same forked containers (`andrewkidd/nfs-server`, `andrewkidd/tftp-server`) used by both the bootstrap VM and the in-cluster netboot stack.

Keep this in mind when prioritising. The design is already coherent — most items below are hardening, not rework.

---

## Tier 1 — Would actually bite under the stated scope

Things that aren't theoretical risks for a hobby-cloud-on-LAN setup.

### Public-repo secret hygiene (SOPS)

- The Dex admin password is `bcrypt(ubuntu)` in the public repo. Brute-forceable on a laptop in minutes.
- OIDC client secret is the literal string `dex-oidc-secret`, also in the repo, also used by three apps (Headlamp, Argo CD, Omni).
- Anyone who reads the repo can construct a working OIDC client against your Dex.
- **Fix**: SOPS-encrypted values files. Argo CD has a SOPS plugin (or use the `helm-secrets` plugin). Decryption key lives on the node, not in git.
- **Effort**: ~half day. Low-risk change.

### Backups (the missing Velero story)

- Longhorn volumes have replication but no backup.
- A Longhorn rebalance race / corrupted replica means data loss.
- For Minecraft + similar hobby workloads, losing the volume = losing the world = "what was the point of this cluster again".
- **Fix**: Velero with a restic or Longhorn-native backup target. Cheap S3-compatible bucket (Backblaze B2, Wasabi, even Cloudflare R2) is fine.
- **Effort**: ~1-2 days including a restore drill.
- Already mentioned in [docs/.../deploy-core-workloads.md](docs/src/content/docs/Getting%20Started/deploy-core-workloads.md) as future work; this is the prompt to actually do it.

### DR drill (proving the self-reproducing claim)

- "Self-reproducing cluster" is a property that has to be exercised. Has the cluster ever been deliberately destroyed and rebuilt from cold without manual intervention?
- The midwife VM rebuilds the netboot infra but cannot rebuild persistent state (Longhorn, Dex passwords, etc.) — once backups exist (above), a real DR drill becomes feasible.
- **Action**: Schedule a quarter where you nuke everything and rebuild from `start.sh` + a Velero restore. Document what broke.

### Renovate Bot

- `INSTALL_K3S_VERSION="v1.33.6+k3s1"` is pinned. Helm chart versions (`targetRevision: 0.19.0` for Dex, `0.36.0` for Headlamp, etc.) are pinned. CVEs accumulate silently.
- **Fix**: Renovate is free for public repos. Single config file (`renovate.json`) at repo root opens PRs for outdated versions automatically.
- **Effort**: ~30 minutes. Single biggest "ops debt reduction per hour spent" item.

---

## Tier 2 — Defensive depth (when bored, or after Tier 1)

### k3s secrets encryption at rest

- Currently k3s stores Secrets unencrypted in etcd. A leaked etcd snapshot leaks every Secret.
- **Fix**: Set `--secrets-encryption` in the k3s install args (already plumbed via `K3S_SERVER_ARGS` in cloud-init).
- **Effort**: 1 line, one boot to verify.

### Image checksum verification

- `curl https://get.k3s.io | sh` trusts whatever Rancher ships.
- Ubuntu image is downloaded over HTTPS but not checksum-verified against the published `SHA256SUMS` from cdimage.ubuntu.com.
- **Fix**: Add a SHA256 verification step to `gen-lab-certs.sh` / the builder Job.
- **Effort**: ~1 hour.

### Argo CD Ingress should use cert-manager

- Already documented as a known issue in [SSO next-steps.md](docs/src/content/docs/Guides/Self%20Signed%20Cluster%20SSO/next-steps.md).
- One annotation change to [user-data:867-891](bootstrap/netboot/assets/ubuntuserver/boot/user-data) brings Argo CD in line with Dex/Headlamp.

### kube-vip RBAC tightening

- Currently `cluster-admin`. Upstream kube-vip docs list the actual minimum role required.
- **Effort**: ~1 hour to replace the binding.

### Audit logging

- k3s API server runs with no audit log. No way to retrospectively investigate "who/what/when."
- **Fix**: `--audit-log-path` + a sensible audit policy.
- For homelab scope this is genuinely low priority unless you ever onboard a second human user.

### Trust-manager YAML indentation in user-data

- [user-data:614-627](bootstrap/netboot/assets/ubuntuserver/boot/user-data) inline trust-manager HelmChart appears to have `metadata:` over-indented relative to `kind:`, which should be parse-invalid YAML. Reconciliation works in the cluster, which suggests trust-manager is installed via some other path or the indentation issue is illusory in context.
- **Action**: `kubectl -n cert-manager get pods` and read the actual HelmChart status to confirm what's installed and from where.

---

## Tier 3 — Design issues that scale with departure from "single-site LAN"

These mostly don't bite under current scope but become real fast if scope expands.

### ARP spoofing the VIP

- kube-vip claims `192.168.1.59` via gratuitous ARP. Anyone on the LAN can counterfeit ARP and steal it, then serve poisoned TFTP/NFS/HTTP to the next booting Pi.
- Mitigation under current scope: trusted LAN. Mitigation if scope grows: separate VLAN with no other devices, or WireGuard mesh between nodes so VIP traffic is ignored if it doesn't come over the encrypted tunnel.

### CA private key on every node

- `/etc/k3s-certs/lab-ca.key` is unencrypted on every cluster node.
- Compromise of any one node = CA leak = ability to mint trusted certs for any cluster service.
- Mitigation under current scope: physical control + LAN trust.
- Mitigation if scope grows: air-gapped CA, online intermediate only. The cluster never sees the root key. Slightly fiddly to set up but conceptually clean.

### NFS `no_root_squash` + read-only shared OS

- Every Pi mounts the same OS share with UID 0 = real UID 0. Privileged action on one node can corrupt the OS share for all.
- Acceptable under current scope (single-tenant, you-trust-yourself).

### Leader-election split brain

- `/tmp/k3s/k3s-leader` is a single-writer file with no quorum. Two nodes booting simultaneously could both think they're the leader.
- The race window is small but real. Works fine at 2-3 nodes; gets dicier past that.
- Future work: replace with K8s lease object (or just pick HA k3s embedded etcd with 3+ control planes).

---

## Tier 4 — Observability

Currently absent. Under current scope ("the cluster is up when I notice the website is up") this is fine. Becomes more pressing as workload count grows.

- Prometheus + node-exporter + kube-state-metrics.
- Grafana for dashboards.
- Loki for log aggregation.
- Alertmanager → ntfy.sh / pushover / discord for actual alerts.
- All deployable as Argo CD apps following the existing pattern.

The first time a workload silently OOM-loops without you noticing for a week, this becomes Tier 1.

---

## Active direction — Talos/Omni v2 chart migration

**Status as of 2026-05-12**: this is the chosen next direction, ahead of Tier 1 security work (which is staying in BACKLOG, not abandoned). The motivation: Sidero released a new Omni chart that *architecturally solves* the TLS stuckness that parked this project.

### What changed upstream

- New chart at `siderolabs/omni:deploy/helm/omni` (v2.x).
- Min Omni app version 1.5.0.
- **The big one**: omni now serves everything (Web UI + gRPC APIs including siderolink) over h2c on a single internal port and demuxes by `Content-Type`. The ingress terminates TLS once. The "mixed-protocol siderolink endpoint" pain is gone by construction.
- Three ingresses by default — `ingress.main`, `ingress.kubernetesProxy`, `ingress.siderolinkApi` — each with its own host + cert.
- Built-in cert-manager integration via `extraObjects`.
- **No upgrade path from v1.** Fresh install only.

### What of the current plumbing becomes obsolete in v2

- `src/manifests/ainur/sidero-omni/siderolink-ingressroute.yaml` — replaced by chart's `ingress.siderolinkApi`.
- `src/manifests/ainur/sidero-omni/omni-servers-transport.yaml` — no more HTTPS backend; h2c only.
- The custom `omni-frontend` Service + the two custom IngressRoutes inside `ingress.yaml` — chart provides its own.
- `volumeMounts.tls` / `volumes.tls` blocks in current `values.yaml` — restructured in v2.

### What stays / ports forward

- GPG etcd encryption (still mandatory) → all the gpg-generator / gpg-backup / gpg-expiry work is preserved.
- `initialUsers` list (same concept).
- Dex OIDC integration (needs porting to v2 `config.auth.oidc` — *shape currently unknown*, see open question below).
- `omnictl-config-secret` + `omni-cluster-template-sync-job` (chart-orthogonal).
- lab-ca custom volume mount.
- Argo CD multi-source Application structure.

### Open question

The v2 chart README documents Auth0 as the worked example for `config.auth`. OIDC is listed as supported but the config schema isn't shown in the README. **Find the v2 OIDC values shape** (likely from `values.yaml` in the chart source) before drafting the new values file.

### Suggested migration sequence (when ready)

1. **Research**: pull the v2 chart source, find the OIDC config schema, draft a new `values.yaml`.
2. **Parallel install**: deploy v2 in `ainur-sidero-omni-v2` namespace, leave v1 untouched.
3. **Smoke test**: verify Dex login works, verify a test Talos node can join via the new siderolink endpoint.
4. **Cut over**: switch DNS for `omni.kidd.network` → v2; archive v1 manifests in git history.
5. **Docs**: write the `bootstrap-arda` and Talos-architecture docs against the v2 setup (they're currently drafted as TODO stubs, which is the right state for not-yet-real things).

### Why this is ahead of Tier 1 security work

Talos work unblocks the x86 cluster, which is a meaningful capability expansion. The Tier 1 security items (SOPS, Velero, Renovate) are valuable but don't unblock anything; they harden what's already working. Different kinds of value.

That said: **don't make the public-repo SOPS gap worse during this work.** If the v2 OIDC config needs a new client secret, treat it as the prompt to actually set up SOPS rather than committing another plaintext secret.

---

## Tier 5 — The Parents' Garage (multi-site future)

Genuinely interesting next step, deferred to "docs finalizer" stage per conversation. Notes for future-me:

- Talos becomes more attractive specifically for this, because Siderolink solves the cross-NAT trust problem that you'd otherwise hand-roll with WireGuard.
- Each site backs up the other → real DR strategy by design, not bolt-on.
- Forces a real authentication story for inter-node traffic (the LAN-trust assumption breaks across the public internet).
- Forces a real DNS story (split-horizon, or one of the dynamic-DNS-tunnel services).
- Federated identity (Dex is *literally* designed for this — multiple connectors, one issuer) finally has a reason to exist beyond "I felt like it."

## Tier 6 — Architectural curiosities

Things that aren't gaps so much as "would be cool experiments":

- **Per-node mTLS for `bootstrap-http`.** Each Pi gets a unique client cert in cloud-init; nginx verifies. The agent token stops being free-for-the-LAN. Issuer is already in place (`local-ca`).
- **TPM-attested node identity** on Pi 4+/5. Bind node identity to a hardware-sealed key. Makes "fresh Pi joins the cluster" verifiable rather than just "anyone with the LAN can join."
- **Per-node ephemeral join tokens** instead of a single static `K3S_AGENT_TOKEN`. k3s supports per-node tokens that can be revoked individually.
- **Self-hosted Renovate runner** on the cluster. Closes the loop one more turn: the cluster suggests its own upgrades.
- **A `talos-arda` sibling section in the docs** once the x86 side comes online — using Talos with `talosctl` directly, no Omni. Compare-and-contrast against the Ubuntu+k3s Pi side. Could be a really nice teaching artifact.

---

## Things I deliberately decided NOT to do

Anti-goals worth remembering so they don't creep back in:

- **Make the docs into a TODO dump.** User-facing docs acknowledge known limits narratively (the "What's still rough" sections); this file is where the unflinching list lives.
- **Adopt Omni for the x86 side just because it's the obvious path.** Tried, found it too opinionated. Plain `talosctl` is the path forward when the x86 work resumes.
- **Add features beyond what serves the hobby-cloud scope.** Multi-tenant, audit, compliance, etc. — out of scope unless and until scope explicitly expands.

---

*Last reviewed: 2026-05-12. Next review: when the parents' garage idea becomes real, or when the first Tier-1 item gets done — whichever comes first.*
