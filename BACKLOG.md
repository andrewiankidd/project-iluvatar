# project-iluvatar — Backlog

Honest internal tracking of gaps, debt, and "would be nice" items that don't belong in the user-facing docs. Reviewed conversationally on 2026-11-17.

The project's intended scope is **a personal homelab cloud** for hobby workloads (Minecraft, Dragonwilds, etc.) plus a k8s/Argo CD sandbox. **ainur** (Pis, k3s) is LAN-trusted and must work fully offline. **arda** (x86, Talos) serves the workloads; its web traffic comes in through a Cloudflare Tunnel and its game ports through router forwards, but everything must still be reachable on the LAN without Cloudflare. The list below is graded against that scope, not against a production-grade deployment.

The standing rule: **nothing manual.** Start the bootstrap VM and everything else follows. A fix that needs a `kubectl` by hand is not finished.

## What's currently good

- Self-reproducing bootstrap loop (ouroboros). The cluster hosts the netboot stack that boots the cluster.
- Everything declarative from cloud-init → k3s HelmChart manifests → Argo CD app-of-apps. Almost no imperative state.
- Honest separation of "stateless ephemeral nodes" from "stateful cluster" via Longhorn + selectable persistence.
- SSO + private CA chain auto-wires across apps with zero manual `kubectl label` steps.
- The same forked containers (`andrewkidd/nfs-server`, `andrewkidd/tftp-server`) used by both the bootstrap VM and the in-cluster netboot stack.
- Minecraft is one folder per server (ApplicationSet), and who plays is in a Secret, not the repo.
- The tunnel only publishes an Ingress that opts in (`kidd.network/tunnel: "true"`).

---

## Active direction — prove the x86 path end to end

**Status as of 2026-11-17**: built, **not yet run**. The lab is powered off.

The blocker that parked the project was trust: Talos machines could be made to trust the lab CA on first boot, but Omni (v1.7.2) installed Talos from a stock image and the CA was lost. Machine config patches could not help, since they arrive only after a machine registers.

What changed:

- **Omni 1.13.3** (chart 2.13.3) builds each machine's installer from the schematic the machine booted with, keeping embedded config documents.
- `sidero-omni/talos-schematic-job.yaml` builds a schematic with the lab CA (`TrustedRootsConfig`) and Omni's join config embedded, plus the Longhorn extensions, and writes `boot.ipxe`.
- `pi-netboot/proxy-dhcp.yaml` answers x86 UEFI PXE only: `ipxe.efi` over TFTP from the VIP, then `boot.ipxe` over HTTP.
- `sidero-omni/arda-bootstrap-job.yaml` installs Argo CD on `talos-default` once it is up, with an `arda` root app.
- The Jobs use Omni's `automation` service account (`initialServiceAccount`) instead of a hand-made PGP identity. That identity could never have worked unattended: Omni only accepts a user key after a browser login, and it caps user-key lifetimes. That is also why the etcd encryption key had been given a 6-hour expiry. It no longer expires.
- Talos v1.14.6, Kubernetes v1.37.1.

### Test sequence (when the lab is next on)

1. Bootstrap ainur from the VM as usual. Check the Omni pod, its three Ingresses and the `omni` Certificate.
2. Both Jobs complete: `kubectl -n ainur-sidero-omni logs job/omni-cluster-template-sync`, `job/talos-schematic`. `curl http://192.168.1.59/talos/boot.ipxe` shows a schematic ID.
3. One x86 machine on UEFI network boot. `kubectl -n ainur-netboot logs deploy/proxy-dhcp` shows its request. It should appear in Omni and be allocated to `talos-default`.
4. **The real test**: after Omni installs and reboots it, it reconnects without intervention. Then power-cycle it, and it reconnects again.
5. `arda-bootstrap` completes and arda's Argo CD shows the `arda` apps, each with its Secret, and Longhorn with a disk on every node.
6. A manual Longhorn backup lands in R2, and restores.

### Things that could still bite

- `proxy-dhcp` uses dnsmasq's `pxe-service` for both the TFTP and iPXE stages; it has never seen a real ProDesk. If the firmware ignores proxy offers, the fallback is the router's own DHCP options 66/67.
- `boot.ipxe` chains to `https://pxe.factory.talos.dev`; iPXE fetches cross-signing certs from `ca.ipxe.org` for that. Online only until the factory is self-hosted (below).
- The `automation` key lasts a year (Omni's maximum). Fine for a lab rebuilt more often than that; if not, the Jobs will start failing on auth.
- The Jobs mount Omni's ReadWriteOnce data volume read-only, pinned to Omni's node by pod affinity.

---

## Tier 1 — arda's foundations (built 2026-11-17, not yet run)

### Secrets without anything manual

- The `ARDA_*` values in the gitignored `bootstrap/netboot/.env` (see `.env.example`) → `pi-netboot-builder.sh` serves them at `/secrets/arda.env` → `arda-secrets.sh` in user-data makes ainur's `arda-secrets` Secret once k3s is ready → `arda-bootstrap-job.yaml` hands each arda app its Secret, hourly.
- Not SOPS or Sealed Secrets: both mean encrypting by hand.
- **Trade-off**: `/secrets/arda.env` is readable by anyone on the LAN while the bootstrap VM runs, as the k3s agent token already is. Fine under LAN trust.
- **Watch**: a value changed in `.env` only reaches the clusters on the next bootstrap from the VM.

### arda storage

- Longhorn 1.13.0 on arda (`src/manifests/arda/longhorn.yml`), the default storage class, on each node's SATA SSD: a Talos `UserVolumeConfig` at `/var/mnt/longhorn` plus the kubelet mount, both cluster-template patches.
- **Watch**: the disk selector is `disk.transport == "sata" && !system_disk`. A node without that SSD gets no Longhorn disk.

### Backups

- Longhorn's own nightly backups (`longhorn/recurring-jobs.yaml`, two weeks kept) to **Cloudflare R2**, bucket `arda-backups`. No Velero: Argo CD rebuilds every Kubernetes object, so only volume data needs backing up.
- **One-off, in Cloudflare**: make the `arda-backups` bucket and an R2 API token for it, then put its keys and endpoint in `.env` as `ARDA_BACKUP_*`.
- **Then**: a DR drill. Nuke everything, rebuild from `start.sh` plus a restore, write down what broke.

### Off the stopgap

- `arda-local` runs Minecraft and Dragonwilds on a workstation until arda is up. Moving them means restoring each world into its Longhorn volume on arda, then retiring the stopgap. Never run both: they share the tunnel and the DNS records.

---

## Tier 2 — Defensive depth (when bored, or after Tier 1)

### Dex secrets in the public repo

- The Dex admin password is `bcrypt(ubuntu)` and the shared OIDC client secret is `dex-oidc-secret`, both in the repo.
- **Accepted for now**: this is still dev. Rotate them once the whole loop is proven, through `.env` like the arda secrets, so they never land in git again.

### Renovate Bot

- Every chart, image and Talos/k3s version is pinned. CVEs accumulate silently.
- **Fix**: `renovate.json` at repo root. ~30 minutes.
- Low priority until everything works end to end.

### k3s secrets encryption at rest

- k3s stores Secrets unencrypted in etcd. A leaked etcd snapshot leaks every Secret.
- **Fix**: `--secrets-encryption` in the k3s install args (already plumbed via `K3S_SERVER_ARGS` in cloud-init). 1 line, one boot to verify.

### Image checksum verification

- `curl https://get.k3s.io | sh` trusts whatever Rancher ships, and the Ubuntu image is not checked against `SHA256SUMS`.
- **Fix**: a SHA256 step in `gen-lab-certs.sh` / the builder Job. ~1 hour.

### Argo CD Ingress should use cert-manager

- Already a known issue in [SSO next-steps.md](docs/src/content/docs/Guides/Self%20Signed%20Cluster%20SSO/next-steps.md). One annotation change in [user-data](bootstrap/netboot/assets/ubuntuserver/boot/user-data) brings Argo CD in line with Dex/Headlamp.

### kube-vip RBAC tightening

- Currently `cluster-admin`. Upstream kube-vip docs list the minimum role. ~1 hour.

### Audit logging

- k3s API server runs with no audit log. Low priority unless a second human ever gets access.

### Trust-manager YAML indentation in user-data

- The inline trust-manager HelmChart in [user-data](bootstrap/netboot/assets/ubuntuserver/boot/user-data) appears to have `metadata:` over-indented relative to `kind:`. Reconciliation works, so either it is installed another way or the issue is illusory. Check `kubectl -n cert-manager get pods` and the HelmChart status.

---

## Tier 3 — Design issues that scale with departure from the stated scope

### ARP spoofing the VIP

- kube-vip claims `192.168.1.59` via gratuitous ARP. Anyone on the LAN can steal it and serve poisoned TFTP/NFS/HTTP, now to x86 machines as well as Pis.
- Under current scope: trusted LAN. If scope grows: separate VLAN, or a WireGuard mesh.

### CA private key on every node

- `/etc/k3s-certs/lab-ca.key` is unencrypted on every ainur node. One node compromised means the CA is leaked.
- If scope grows: offline root CA, online intermediate only.

### NFS `no_root_squash` + read-only shared OS

- Every Pi mounts the same OS share as real root. Acceptable single-tenant.

### Leader-election split brain

- `/tmp/k3s/k3s-leader` is a single-writer file with no quorum. Fine at 2-3 nodes; dicier past that.
- Future: a Kubernetes Lease, or HA k3s with embedded etcd.

---

## Tier 4 — Observability

Currently absent. Fine while "the cluster is up when the website is up"; more pressing as workloads grow.

- Prometheus + node-exporter + kube-state-metrics, Grafana, Loki.
- Alertmanager → ntfy.sh / pushover / discord.
- All deployable as Argo CD apps following the existing pattern.

The first time a workload silently OOM-loops for a week, this becomes Tier 1.

---

## Tier 5 — Offline, for real

The North Star is a lab that rebuilds with no internet at all. What still reaches out:

- Talos images from `factory.talos.dev`. **Fix**: self-hosted Image Factory (`siderolabs/image-factory:deploy/helm/image-factory`), then `registries.factories` in Omni's values and the URLs in `talos-schematic-job.yaml`. Its `pxeURL` can be plain HTTP on the LAN, which also drops iPXE's reliance on `ca.ipxe.org`.
- Container images, Helm charts, `omnictl` and Argo CD from GitHub. **Fix**: a registry mirror / pull-through cache on ainur.
- The repo itself, from GitHub.
- The Cloudflare Tunnel and DNS are online by nature; the LAN path has to keep working without them.

---

## Tier 6 — The Parents' Garage (multi-site future)

Deferred to "docs finalizer" stage. Notes for future-me:

- Siderolink solves the cross-NAT trust problem that you'd otherwise hand-roll with WireGuard.
- Each site backs up the other: real DR by design.
- Forces real inter-node authentication, a real DNS story (split-horizon), and gives Dex's multiple connectors a reason to exist.

## Tier 7 — Architectural curiosities

- **Per-node mTLS for `bootstrap-http`.** Each Pi gets a client cert in cloud-init; nginx verifies. Issuer already exists (`local-ca`).
- **TPM-attested node identity** on Pi 4+/5.
- **Per-node ephemeral join tokens** instead of one static `K3S_AGENT_TOKEN`.
- **Self-hosted Renovate runner** on the cluster: the cluster suggests its own upgrades.
- **A `talos-arda` docs section** comparing plain `talosctl` with the Omni path, against the Ubuntu+k3s Pi side.

---

## Things I deliberately decided NOT to do

- **Make the docs into a TODO dump.** User-facing docs acknowledge known limits narratively; this file is where the unflinching list lives.
- **Let's Encrypt, or any public CA.** Ruled out by the offline constraint. The self-signed lab CA is the design, not a shortcut.
- **Manual secrets tooling.** No SOPS, no Sealed Secrets, nothing that needs hand-encrypting.
- **Add features beyond what serves the hobby-cloud scope.** Multi-tenant, audit, compliance, etc. stay out unless scope explicitly expands.

---

*Last reviewed: 2026-11-17. Next review: after the first end-to-end run of the x86 path.*
