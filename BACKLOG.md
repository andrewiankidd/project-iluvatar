# project-iluvatar — Backlog

Honest internal tracking of gaps, debt, and "would be nice" items that don't belong in the user-facing docs. Reviewed conversationally on 2026-11-17.

The project's intended scope is **a personal homelab cloud** for hobby workloads (Minecraft, Dragonwilds, etc.) plus a k8s/Argo CD sandbox. **ainur** (Pis, k3s) is LAN-trusted and must work fully offline. **arda** (x86, Talos) serves the workloads; its web traffic comes in through a Cloudflare Tunnel and its game ports through router forwards, but everything must still be reachable on the LAN without Cloudflare. The list below is graded against that scope, not against a production-grade deployment.

The standing rule: **nothing manual.** Start the bootstrap VM and everything else follows. A fix that needs a `kubectl` by hand is not finished.

## What's currently good

- Self-reproducing bootstrap loop (ouroboros). The cluster hosts the netboot stack that boots the cluster.
- Everything declarative from cloud-init → k3s HelmChart manifests → Argo CD app-of-apps. Almost no imperative state.
- Honest separation of "stateless ephemeral nodes" from "stateful cluster" via Longhorn + selectable persistence. Not yet across a rebuild: see "Next direction".
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
- Talos v1.14.5, Kubernetes v1.37.1.

### Test sequence (when the lab is next on)

1. Bootstrap ainur from the VM, then `bootstrap/netboot/rebootstrap.sh` so the SD card Pi isn't left on an old build. Check the Omni pod, its three Ingresses and the `omni` Certificate.
2. Both Jobs complete: `kubectl -n ainur-sidero-omni logs job/omni-cluster-template-sync`, `job/talos-schematic`. `curl http://192.168.1.59/talos/boot.ipxe` shows a schematic ID, and `kubectl -n ainur-netboot logs job/talos-iso` says the ISO is cached.
3. One x86 machine, booted from a USB stick written from `http://bootstrap.kidd.network/talos-media/metal-amd64.iso` (Secure Boot off). Network boot (`kubectl -n ainur-netboot logs deploy/proxy-dhcp`) is untried and can come later. It should appear in Omni and be allocated to `talos-default` as its control plane. That one machine is already a working cluster; the rest join as workers whenever they are switched on.
4. **The real test**: after Omni installs and reboots it, it reconnects without intervention. Then power-cycle it, and it reconnects again.
5. `arda-bootstrap` completes and arda's Argo CD shows the `arda` apps, each with its Secret, and Longhorn with a disk on every node.
6. A manual Longhorn backup lands in R2, and restores.

### Things that could still bite

- **Omni's old state.** If Omni's data volume on ainur survived from v1.7.2, v1.13.3 has to migrate it across six releases. And `gpg-generator.yaml` always makes a new etcd key, backing it up but never restoring it, so a rebuilt ainur cannot read Omni's saved state. There is no Talos cluster worth keeping, so Omni starting empty is the safe path: `bootstrap/netboot/rebootstrap.sh` gives the whole of ainur a fresh start, Omni included.
- With fewer than three machines, Longhorn's volumes run degraded (three replicas wanted) until more join.
- After the install, the disk has to boot before the USB stick, or the machine just boots the ISO again.
- `proxy-dhcp` uses dnsmasq's `pxe-service` for both the TFTP and iPXE stages; it has never seen a real ProDesk. If the firmware ignores proxy offers, the fallback is the router's own DHCP options 66/67.
- `boot.ipxe` chains to `https://pxe.factory.talos.dev`; iPXE fetches cross-signing certs from `ca.ipxe.org` for that. Online only until the factory is self-hosted (below).
- The `automation` key lasts a year (Omni's maximum). Fine for a lab rebuilt more often than that; if not, the Jobs will start failing on auth.
- The Jobs mount Omni's ReadWriteOnce data volume read-only, pinned to Omni's node by pod affinity.

---

## Next direction — stateless nodes, data that survives a rebuild

**Status as of 2026-11-17**: designed, not built. After `talos-default` is up.

Today a re-bootstrap throws everything away. The NVMe drives keep Longhorn's replicas, but the new cluster can't use them: what makes a replica a volume (which volume it belongs to, which copies are in sync, which PVC it serves) lives in etcd, and a fresh etcd sees only orphaned folders. Longhorn won't adopt them, and shouldn't: it can't tell a stale copy from a current one.

The design: **etcd snapshots in S3, restored by any fresh cluster that finds one.**

- **Nodes stay stateless.** OS from netboot or the SD card, etcd on the RAM disk, as now. Nothing on a node needs keeping, and the SD card Pi can be re-flashed at will.
- **The NVMe is Longhorn's alone**, data only, replicated across the Pis. PVCs are declared in Git.
- **The index lives in a bucket.** k3s saves etcd snapshots to S3 on a schedule (`--etcd-s3`, `--etcd-snapshot-schedule-cron`). Before k3s starts on a server with an empty datastore, a step looks in the bucket: if there's a snapshot it restores the latest (`--cluster-reset --cluster-reset-restore-path=<latest>`), if not it's a first boot. Restored, Longhorn's records point at the replicas still on the NVMe (each disk keeps an ID that matches), and the PVCs bind to the same data.
- **arda the same way**: Omni can back up each cluster's etcd to S3 itself.

What it needs:

1. **A fixed k3s server token**, in `.env` like the `ARDA_*` values. Snapshots are encrypted with it; a random token per bootstrap can't read the last one.
2. **Fresh snapshots.** `rebootstrap.sh` takes one before it reboots anything (as arda-local backs up before stopping), plus a schedule. Anything made after the last snapshot comes back orphaned; most other drift heals itself, since Argo CD re-applies Git.
3. **Node passwords.** k3s records a password per node in etcd, and keeps the node's copy on the node. A netbooted Pi forgets its copy, so a restored cluster would turn it away. Keep the file on the NVMe, or clear the recorded passwords once after a restore.
4. **A LAN S3 target for offline.** k3s writes to one target; R2 works today. Offline, it becomes an S3 server on the LAN, with R2 as the off-site copy.
5. **The Omni GPG key restored, not regenerated.** `gpg-generator.yaml` makes a new key every time and only ever writes its backup, so Omni's restored state would be unreadable. Restore it from the backup when there is one.

Still not covered: re-flashing the control plane takes the VIP down while it netboots (kube-vip's leader election goes through its API server), so that re-flash still needs the bootstrap VM serving netboot. It now comes back as the same cluster rather than a new one. With that, rebuilding the Pi image in the cluster on demand (re-run the builder Job; the SD card Pi checks the image hash on a timer) becomes worth doing.

Considered and set aside:

- **Keeping etcd on the NVMe**, with all three Pis as control planes. Works, and keeps the VIP up through any one reboot, but the nodes stop being stateless and the bootstrap scripts change throughout.
- **Static local volumes at fixed paths.** Survive a rebuild with no snapshot, but give up Longhorn's replication.
- **Back up, rebuild, restore the volumes** (Longhorn system backup). Throws away the replicas on every rebuild.
- **Ceph through Rook**, which can adopt its own disks. Far too heavy for Pis.

---

## Tier 1 — arda's foundations (built 2026-11-17, not yet run)

### Secrets without anything manual

- The `ARDA_*` values in the gitignored `bootstrap/netboot/.env` (see `.env.example`) → `pi-netboot-builder.sh` serves them at `/secrets/arda.env` → `arda-secrets.sh` in user-data makes ainur's `arda-secrets` Secret once k3s is ready → `arda-bootstrap-job.yaml` hands each arda app its Secret, hourly.
- Not SOPS or Sealed Secrets: both mean encrypting by hand.
- **Trade-off**: `/secrets/arda.env` is readable by anyone on the LAN while the bootstrap VM runs, as the k3s agent token already is. Fine under LAN trust.
- **Watch**: a value changed in `.env` only reaches the clusters on the next bootstrap from the VM.

### arda storage

- Longhorn 1.13.0 on arda (`src/manifests/arda/longhorn.yml`), the default storage class, on each node's SATA SSD: a Talos `UserVolumeConfig` at `/var/mnt/longhorn` (cluster-template patch, selector `disk.transport == "sata"`; Talos 1.14 has no `system_disk` and no kubelet `extraMounts`, and needs neither).
- ainur's `arda-disks` CronJob wipes an SSD that arrives with old partitions (Talos won't), then labels the node `node.longhorn.io/create-default-disk=true`; Longhorn only makes a disk on labelled nodes, so it never writes to the bare directory before the SSD is mounted there.
- **Watch**: a node without a SATA SSD gets no Longhorn disk. With one node, every volume is degraded (3 replicas wanted).
- **Recreate** the three game volumes made on 2026-11-18 before the SSD was mounted (two faulted, survival only alive while its files stay open). Fresh worlds, no backups.

### Backups

- Longhorn's own nightly backups (`longhorn/recurring-jobs.yaml`, two weeks kept) to **Cloudflare R2**, bucket `arda-backups`. No Velero: Argo CD rebuilds every Kubernetes object, so only volume data needs backing up.
- The bucket exists (2026-11-17, Western Europe), and `ARDA_BACKUP_*` are in `.env`: an R2 token's ID as the access key, the SHA-256 of its value as the secret. They passed an S3 write, list and delete. Rolling or deleting that token stops backups until the keys are derived again.
- **Then**: a DR drill. Nuke everything, rebuild from `start.sh` plus a restore, write down what broke.

### Off the stopgap

- `arda-local` runs Minecraft and Dragonwilds on a workstation until arda is up. It reads the same `ARDA_*` names from its own `.env`, so the lines are shared. Moving them means restoring each world into its Longhorn volume on arda, then retiring the stopgap. Never run both: they share the tunnel and the DNS records.

### More workloads

- Planned on the x86 page, none built: Jellyfin, Paperless, Bitwarden, Crafty, LlamaGPT. Each would be an Argo CD app under `src/manifests/arda` storing its data on Longhorn, with any secrets coming from `.env`.
- After the x86 path is proven and the stopgap retired.
- **Bitwarden**: Vaultwarden is the usual lightweight server; Dex in front like the rest.
- **Media**: Jellyfin, with Sonarr/Radarr (and Lidarr if music), Prowlarr (Jackett's successor) for indexers, Bazarr for subtitles, and a download client. Needs bulk storage (see Hardware): a ProDesk's SSD under Longhorn's three replicas is no place for a library. Transcoding needs no GPU: the ProDesks' Intel iGPUs do Quick Sync, given the `i915` extension in the Talos schematic and Intel's GPU device plugin on arda.

### Home Assistant and a local assistant (the end goal)

- Replace Google Nest and the Hue cloud with Home Assistant plus a local LLM voice assistant: Whisper (speech to text), Piper (text to speech), Ollama behind Home Assistant's Assist, and Home Assistant voice satellites where the Nest speakers are. All local, so it fits the offline rule.
- **Zigbee over the network, not USB**: a PoE Ethernet coordinator (SLZB-06-style) lets Home Assistant run on arda without being pinned to the node with the dongle. Hue bulbs are Zigbee and pair to it directly, so the bridge and its cloud go.
- **The LLM starts on CPU.** GPUs are out of budget. Home Assistant's own intent matching handles plain commands instantly with no LLM; a small quantized model (3B-8B, Ollama) on a ProDesk handles the rest in seconds. A GPU box later changes nothing else. Supersedes LlamaGPT.
- On the Lab VLAN, its IoT devices on IoT. Whatever the household uses has to keep working mid-rebuild, so keep a manual fallback (switches, the Hue app) until it has earned trust.
- If the Nest setup includes cameras or a doorbell: UniFi Protect records locally and Home Assistant integrates with it.

### Observability (promoted from Tier 4, 2026-11-18)

Absent, and 2026-11-18 showed what that costs: valar-51/52 hung with no record of why, the NVMe dropouts were found from console screenshots, and Longhorn volumes faulted silently.

- Metrics: kube-prometheus-stack (Prometheus, node-exporter, kube-state-metrics, Grafana, Alertmanager) on ainur, scraping arda too.
- Logs: Loki with Alloy, collecting both clusters' pods and UniFi's firewall/system logs over syslog. With the GeoLite2 database, that's a map of who hits the forwarded game ports.
- Alerts somewhere local (self-hosted ntfy), so a hung node or a faulted volume says so. Blackbox checks (or Uptime Kuma) for "does the service answer from outside".
- Grafana behind Dex; Homepage finds it by its annotations. All Argo CD apps, as usual.

---

## Tier 2 — Defensive depth (when bored, or after Tier 1)

### Rotate the burner credentials

- The Pi password, k3s tokens, Dex admin hash, OIDC client secret and Homepage session key are now `AINUR_*` in the bootstrap `.env` (`ainur-secrets.sh` makes them Secrets; the builder fills user-data), not in the repo. Their values are still the old burner ones, which stay in git history.
- **Then**: new values in `.env` and a rebootstrap. The Pis' SSH could also move from a password to a key.

### VLANs

- Everything shares one LAN. Minecraft and Dragonwilds take port forwards from the internet, so a hole in a server or plugin puts someone next to the Pis' SSH and every admin UI.
- **Plan**: Infrastructure (UniFi, JetKVMs, PDU/UPS), Lab (ainur, arda, the bootstrap VM), Exposed (game servers and anything else published: reaches nothing else), Work (the work laptop), Users, Guests, IoT (Home Assistant's devices).
- **Watch**: netboot (option 66, TFTP, NFS, proxy DHCP) and kube-vip's ARP on `.59` all assume one segment; the Pis and the VM have to stay together, and DHCP relay or per-VLAN options decide what crosses. Plan it before moving anything.
- Remote access is UniFi Teleport (or its plain WireGuard server); clients need the gateway as DNS for `*.kidd.network`, and the lab CA installed.

### The bootstrap VM's proxy DHCP never starts

- dnsmasq in the VM fails with "port 53 already in use" (systemd-resolved holds it), so the VM never answers netboot itself; the router's DHCP option 66 has to point at it.
- **Fix**: `port=0` in `vm/init/render-dnsmasq.sh`, so dnsmasq does DHCP only. Check what `dhcp-authoritative` does next to the router's DHCP first.

### proxy-dhcp answers the Pis too

- `pi-netboot/proxy-dhcp.yaml` is meant for x86 UEFI only, but it answers the Pis' requests (`PXEClient:Arch:00000`) as well. They boot anyway, from option 66.
- **Fix**: only answer client architectures 7 and 9 (x86-64 UEFI).

### One boot address

- Option 66 points at the VM (`.66`) while bootstrapping and at the VIP (`.59`) after, changed by hand.
- **Fix**: the VIP takes over `.66` once the VM steps back, so option 66 never changes.

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

- `/tmp/k3s/k3s-leader` is a single-writer file with no quorum. Fine at 2-3 nodes; dicier past that. Its sharpest edge, losing the cluster with the leader, is what the etcd snapshots in "Next direction" take away.
- Future: a Kubernetes Lease, or HA k3s with embedded etcd.

---

## Tier 4 — Hardware, when prices allow

- **A UPS, with NUT.** A power cut is harmless to the stateless Pis, not to Longhorn volumes mid-write, Omni's state or the game worlds. NUT shuts the clusters down cleanly before the battery does. A UniFi UPS reports into the same controller.
- **A switched, metered PDU** for the ProDesks, the one thing not on PoE: remote power-cycle for a hung machine (BIOS *After Power Loss: Power On*) and per-outlet draw to spot one. The UniFi SmartPower PDU Pro if a UK model exists; a used APC AP79xx/AP88xx otherwise.
- **Bulk storage** (a UNAS Pro 8, 10G DAC to the switch's SFP+) for the media stack, over NFS/SMB. Drives are the expensive part.
- **UniFi Protect**: the UDM SE runs it, recording to its 3.5" bay. Doorbell and cameras on a Switch Flex fed from a PoE++ port on the Pro-24-PoE.
- **Three 4-port KVM switches** behind the three JetKVMs (ProDesks; Pis; front-of-rack plus desktop and work laptop). Must switch on hotkeys over USB pass-through (JetKVM is a composite device), with EDID emulation; full USB switching keeps JetKVM's virtual media usable.

---

## Tier 5 — Offline, for real

The North Star is a lab that rebuilds with no internet at all. What still reaches out:

- Talos images from `factory.talos.dev`. **Fix**: self-hosted Image Factory (`siderolabs/image-factory:deploy/helm/image-factory`), then `registries.factories` in Omni's values and the URLs in `talos-schematic-job.yaml`. Its `pxeURL` can be plain HTTP on the LAN, which also drops iPXE's reliance on `ca.ipxe.org`.
- Container images, Helm charts, `omnictl` and Argo CD from GitHub. **Fix**: a registry mirror / pull-through cache on ainur.
- The repo itself, from GitHub: both Argo CDs, template sync, the builder and arda-bootstrap clone it, so with the internet down nothing can change or rebuild. **Fix**: a Git mirror (Forgejo or Gitea) that they read from, GitHub staying the public copy. Probably an offsite Pi, so a rebuild of ainur doesn't take its own source with it and the source has an off-site copy (see Tier 6). The easiest piece of this tier.
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
- **A public template and a private config.** The public repo keeps the code with `example.com` placeholders (`home.arpa` suits a LAN-only setup); a private repo holds the real domain, addresses and Dex users, as the `$values` source most apps already use. The domain is written into Ingresses, user-data and Omni's template today, so it first needs to become one setting. A private repo also needs a token in `.env` for Argo CD (ainur and arda), the in-cluster builder and Omni's template sync, which all clone from GitHub.

---

## Things I deliberately decided NOT to do

- **Make the docs into a TODO dump.** User-facing docs acknowledge known limits narratively; this file is where the unflinching list lives.
- **Let's Encrypt, or any public CA.** Ruled out by the offline constraint. The self-signed lab CA is the design, not a shortcut.
- **Manual secrets tooling.** No SOPS, no Sealed Secrets, nothing that needs hand-encrypting.
- **Add features beyond what serves the hobby-cloud scope.** Multi-tenant, audit, compliance, etc. stay out unless scope explicitly expands.

---

*Last reviewed: 2026-11-18, after the first end-to-end run of the x86 path and a pass through saved r/homelab posts.*
