# project-iluvatar — Backlog

Honest internal tracking of gaps, debt, and "would be nice" items that don't belong in the user-facing docs. Reviewed conversationally on 2026-11-17; brought up to date 2026-11-23.

The project's intended scope is **a personal homelab cloud** for hobby workloads (Minecraft, Dragonwilds, etc.) plus a k8s/Argo CD sandbox. **ainur** (Pis, k3s) is LAN-trusted and must work fully offline. **arda** (x86, Talos) serves the workloads; its web traffic comes in through a Cloudflare Tunnel and its game ports through router forwards, but everything must still be reachable on the LAN without Cloudflare. The list below is graded against that scope, not against a production-grade deployment.

The standing rule: **nothing manual.** Start the bootstrap VM and everything else follows. A fix that needs a `kubectl` by hand is not finished.

## What's currently good

- Self-reproducing bootstrap loop (ouroboros). The cluster hosts the netboot stack that boots the cluster.
- Everything declarative from cloud-init → k3s HelmChart manifests → Argo CD app-of-apps. Almost no imperative state.
- Honest separation of "stateless ephemeral nodes" from "stateful cluster": arda's volumes on Longhorn, backed up to R2; ainur's few on valar-50's NVMe (local-path). See "Next direction".
- SSO + private CA chain auto-wires across apps with zero manual `kubectl label` steps.
- The same forked containers (`andrewkidd/nfs-server`, `andrewkidd/tftp-server`) used by both the bootstrap VM and the in-cluster netboot stack.
- Minecraft is one folder per server (ApplicationSet), and who plays is in a Secret, not the repo.
- The tunnel only publishes an Ingress that opts in (`kidd.network/tunnel: "true"`).

## Open, at a glance (2026-11-23)

The detail is in each section below; this is only the list.

- **Waiting on a person or hardware**: Plex's libraries (claimed 2026-11-23); Jellyfin's and Seerr's wizards; Bazarr's languages (Media). Hue pairing, the Matter devices, voice satellites, a Zigbee coordinator (Home Assistant). LiveSync in each vault (Obsidian). A mailbox, the phone app (Paperless). Retiring the GitLab VM runner. valar-51's NVMe ribbon.
- **Security** (Security sweep): High: the pusher trusts any SSH host; any x86 machine joins arda; unverified `omnictl` with Omni's master key; the privileged, unpinned netboot builder. Medium: no TLS check to ainur or UniFi; LLDAP's Role over `arda-secrets`; CouchDB's admin on the internet; no login throttle on Dex or Paperless; kube-vip and CI privilege. More NetworkPolicies, now that arda enforces them (CouchDB, LLDAP, CI).
- **Infrastructure**: VLANs (closes the first two High items; Tier 2). External Secrets Operator. Small fixes: k3s secrets encryption, Renovate, image checksums, the VM's dnsmasq, proxy-dhcp answering the Pis, one boot address. The lab CA re-issued with key usage. Secure Boot on arda. The netboot volumes on `local-path-kept` at the next ainur rebuild. A whole-lab DR drill and a LAN copy of the backups. ainur's SQLite datastore (watch).
- **Metrics**: Plex and Jellyfin streams, a CI dashboard, UniFi's syslog.
- **Later tiers**: hardware (Tier 4), offline (Tier 5), a second site (Tier 6).

---

## Active direction — prove the x86 path end to end

**Status as of 2026-11-18**: **proven**, by network boot rather than a USB stick. After ainur was rebuilt, ProDesk-0 was reset from ainur's network boot menu (**Talos (Reset system disk)**), registered with the new Omni, became `talos-default`'s control plane as `valinor-53`, and `arda-bootstrap` installed Argo CD on it. Docs: getting-started/bootstrap-arda and rebootstrap-arda, and the Netbooting x86 guides.

What the first real run turned up, all fixed:

- `ipxe.efi` was mounted over the TFTP volume, and the image builder's `rsync --delete` unmounted it once the volume was a local directory: *File not found*. Now copied in, and skipped by the builder's syncs.
- The ProDesk's network card only did legacy PXE until its firmware was set to *Option ROM Launch Policy: All UEFI* and legacy support off.
- Every ainur rebuild made a new lab CA, so the ProDesk, installed under the old one, couldn't reach the new Omni. The CA now comes from `.env`.
- Both machine sets drew on one class and Omni put the only machine in the workers, leaving no control plane. Workers now need `kidd.network/arda-worker`, which `arda-disks` gives only once the control plane is filled.
- Template patches deleting a control-plane taint and label failed on a worker's config. The taint delete moved under `ControlPlane:`; MetalLB ignores the label instead (`--ignore-exclude-lb`).

The rest of this section is the original plan, kept for the record.

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
5. `arda-bootstrap` completes and ainur's Argo CD shows the `arda` apps, each with its Secret, and Longhorn with a disk on every node.
6. A volume's backup lands in R2, and restores. (Done with VolSync instead, 2026-11-19.)

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

**Status as of 2026-11-18**: done, another way. Data survives a rebuild by restoring each volume from R2, not by restoring the cluster's datastore.

A re-bootstrap still starts every cluster from an empty datastore, but each volume worth keeping is backed up to R2 nightly by VolSync (restic, from a Longhorn snapshot) and created *from* its latest backup: the PVC's `dataSourceRef` names a ReplicationDestination, so it waits, Pending, until its data is back, and a brand-new one starts empty.

- **arda: every Longhorn volume**, chart-made ones included, wired by a Kyverno policy (`src/manifests/arda/kyverno-policies/volsync.yaml`). Tested end to end: write, back up, delete, recreate, same data back. Longhorn's own R2 backups are gone.
- **ainur: Omni's data and its GPG key** (2026-11-19). They live at fixed paths on valar-50's NVMe (StorageClass `local-path-kept`, `<namespace>/<claim>/data`, kept when the claim goes), so a re-flashed valar-50 finds them. The `omni-backup` CronJob stops Omni at 03:30 (its embedded etcd has no client port to snapshot through; about 13 s down) and restic-backs-up both to `arda-backups/omni` in R2; the `omni-restore` Job puts them back when the folder is empty, before the GPG Job and Omni. Tested: data moved aside and the Secret deleted, restored from R2, and the same Omni came back with its cluster and machine. Everything else on ainur rebuilds from Git and `.env`.
- **The GPG key is restored, not regenerated**: `gpg-generator.yaml` now uses the saved key when there is one.
- **Netbooted Pis keep their node password**: derived from the agent token and hostname, so they rejoin after a reboot without anything stored.
- **ainur's k3s uses SQLite**, not etcd. It has one server (the netbooted Pis can't hold a datastore), and etcd's constant small writes on the SD card stalled the API whenever the card was busy. With nothing on ainur worth restoring, there's no datastore snapshot to keep.
- **Nodes stay stateless.** The SD card Pi can be re-flashed at will; the NVMe holds only volumes.
- **ainur has no Longhorn.** Its volumes (netboot files, Omni) are local-path on valar-50's NVMe, `/var/mnt/nvme/local-path`, with Omni, the netboot servers and the VIP pinned beside them. Longhorn's pods and 2 GB of images filled the netbooted Pis' RAM disks, and the replication couldn't outlive valar-50, the only k3s server, anyway.
- **Two PriorityClasses** on ainur, `ainur-critical` and `ainur-optional`, so a Pi short of memory evicts Homepage before Omni. Headlamp's chart has no setting for one, so it stays at 0.

Open:

- **The netboot volumes on a rebuild** still use plain local-path, so a rebuilt ainur makes new folders and leaves the old `pvc-*` ones on valar-50's NVMe. They rebuild from Git, so nothing is lost. Checked 2026-11-21: none orphaned yet (all 8 folders belong to Bound claims). The fix is `local-path-kept` for them, but a claim's class can't change in place and `pi-netboot-os` is the netbooted Pis' live NFS root, so switch at the next ainur rebuild, when they're recreated anyway.
- **An offline restore.** `omni-restore` fails rather than start Omni empty if R2 can't be reached, so a new NVMe with no internet leaves Omni waiting. A LAN S3 target would cover it.
- **The lab CA survives a rebuild now** (2026-11-18): `AINUR_LAB_CA_CRT`/`AINUR_LAB_CA_KEY` in `.env`, used by `gen-lab-certs.sh`. Until then every rebuild made a new CA on valar-50's SD card, and every arda machine (and device) stopped trusting Omni.
- **valar-51/52's NVMe** sit unused. valar-50's old Longhorn replicas (59 GB under `/var/mnt/nvme/replicas`, unused since ainur dropped Longhorn on 2026-11-18) were deleted 2026-11-21; it now holds only `local-path`, 15 GB of 120.
- Rebuilding the control plane still takes the VIP down while it netboots, so that re-flash needs the bootstrap VM serving netboot (`rebootstrap.sh` now points DHCP option 66 at it and ainur's `unifi` CronJob points it back).

Considered and set aside:

- **etcd snapshots in S3**, restored by a fresh cluster before k3s starts (`--etcd-s3`, `--cluster-reset-restore-path`), so Longhorn's records point at the replicas still on the NVMe. The original design here. Needs a fixed server token, snapshots fresh enough, a LAN S3 target offline, and etcd, which the SD card couldn't carry. Restoring the volumes themselves turned out simpler.
- **Keeping etcd on the NVMe**, with all three Pis as control planes. Works, and keeps the VIP up through any one reboot, but the nodes stop being stateless and the bootstrap scripts change throughout.
- **Static local volumes at fixed paths.** Survive a rebuild with no snapshot, but give up Longhorn's replication.
- **Back up, rebuild, restore the volumes** (Longhorn system backup). Throws away the replicas on every rebuild.
- **Ceph through Rook**, which can adopt its own disks. Far too heavy for Pis.

---

## Tier 1 — arda's foundations (built 2026-11-17, running since 2026-11-18)

### Secrets without anything manual

- The `ARDA_*` values in the gitignored `bootstrap/netboot/.env` (see `.env.example`) → the bootstrap VM's `push-secrets.sh` SSHes them to ainur's k3s server → `arda-secrets.sh` there makes ainur's `arda-secrets` Secret → `arda-bootstrap-job.yaml` hands each arda app its Secret, hourly. `AINUR_*` the same way, into `ainur-secrets`.
- Not SOPS or Sealed Secrets: both mean encrypting by hand.
- The pusher reads `.env` every 30 seconds, so a changed value reaches ainur within a minute while the VM runs, and arda within the hour. Nothing to rebuild.

### arda storage

- Longhorn 1.13.0 on arda (`src/manifests/arda/longhorn.yml`), the default storage class, on each node's SATA SSD: a Talos `UserVolumeConfig` at `/var/mnt/longhorn` (cluster-template patch, selector `disk.transport == "sata"`; Talos 1.14 has no `system_disk` and no kubelet `extraMounts`, and needs neither).
- ainur's `arda-disks` CronJob wipes an SSD that arrives with old partitions (Talos won't), then labels the node `node.longhorn.io/create-default-disk=true`; Longhorn only makes a disk on labelled nodes, so it never writes to the bare directory before the SSD is mounted there.
- **Watch**: a node without a SATA SSD gets no Longhorn disk. With one node, every volume is degraded (3 replicas wanted).
- **Recreate** the three game volumes made on 2026-11-18 before the SSD was mounted (two faulted, survival only alive while its files stay open). Fresh worlds, no backups.

### Backups

**In place, checked 2026-11-21**: all 15 of arda's backed-up volumes (Home Assistant, Paperless, Obsidian, the media apps' settings, Minecraft, Dragonwilds) backed up successfully at 03:00 that night, and Omni's at 03:32.

- **On Google Drive since 2026-11-23** (the 5 TB plan), R2 kept as the fallback: restic through rclone, which VolSync's mover carries and passes `RCLONE_*` keys to. Your own Google OAuth client (`ARDA_GDRIVE_CLIENT_ID`/`_SECRET`; rclone's shared one is being retired and is heavily rate-limited), scope `drive.file` (rclone sees only what it made), pruned files deleted, not binned. The token comes from `bootstrap/netboot/scripts/gdrive-authorize.ps1`, which writes `ARDA_GDRIVE_TOKEN` to `.env`; without it arda-bootstrap points `volsync-repository` back at R2. The 1,004 files of R2's repositories were copied first (checked: 0 differences), so history carried over. Checked: a manual backup of `media/bazarr-config` to Drive, incremental on the copied history, then a restore into a scratch volume, byte-identical to the live one. Kyverno refuses any change to a generate rule (by position), so the policy has `orphanDownstreamOnPolicyDelete` and a change means deleting it for Argo CD to recreate; its secrets and backups stay. Still on R2: Omni's and LLDAP's backups (ainur's own jobs; their history is on Drive too). Google's 750 GB/day upload cap only matters for a first full copy.
- **Backrest** (2026-11-24, `arda/backrest.yml`) at backups.kidd.network, LAN only, behind the Dex login: a web UI over the restic repositories, to browse a volume's snapshots and restore or download files. Its repository list is made at each start from what is on Drive (27, including volumes of apps since removed), read-only (no plans, prune or check; `--no-lock`). Only `RCLONE_*` in its environment: `RESTIC_PASSWORD` there makes it refuse to start (its issue 1139). Shows nothing while backups are on R2. It lists only snapshots it has indexed, and indexes by itself only repositories added in its UI, so an `index` sidecar asks it to index every repository at start and every 6 hours (without it every page said "no backups yet"). Checked: 27 repositories with GUIDs, 77 snapshots indexed within minutes, `media/bazarr-config`'s snapshots from 2026-11-20 on through its API, the site 302s to Dex.
- **Longhorn keeps two replicas** (2026-11-23): two SSD nodes today (valinor-53, -56), ~2 TB usable with four 1 TB SSDs. All 61 volumes moved from 3 (degraded) to 2 (healthy).
- **VolSync**, not Longhorn's own backups or Velero: every Longhorn volume nightly at 03:00 (`arda-backups/volsync/<namespace>/<pvc>`), restic, from a Longhorn snapshot. A Kyverno policy (`kyverno-policies/volsync.yaml`) wires every claim, so a new app is backed up with nothing added. Kept: last 5, 7 daily, 4 weekly, 6 monthly. Argo CD rebuilds every Kubernetes object, so only volume data needs backing up.
- **Restore is automatic**: each claim is created from its latest backup (`dataSourceRef`). Tested end to end, 2026-11-18.
- **Out on purpose** (`kidd.network/backup: "false"`): the 200 GiB media library (can be fetched again) and `paperless-consume` (an inbox).
- **Omni** (ainur): the `omni-backup` CronJob, nightly at 03:32, to `arda-backups/omni`; restored by `omni-restore` on a fresh ainur. Tested 2026-11-19.
- **Alerts**: `VolumeBackupMissing` and `OmniBackupMissing` go to the phone through ntfy.
- The bucket exists (2026-11-17, Western Europe), and `ARDA_BACKUP_*` are in `.env`: an R2 token's ID as the access key, the SHA-256 of its value as the secret. Rolling or deleting that token stops backups until the keys are derived again. `ARDA_VOLSYNC_PASSWORD` decrypts them all: keep a copy outside the lab.
- **Not yet**: a whole-lab DR drill (wipe both clusters, rebuild from `.env` and R2, write down what broke). Each piece has been restored on its own, never all at once. And nothing is copied anywhere but R2, so it's one copy off-site, none on the LAN (see "An offline restore").

### Off the stopgap

- **Creative moved to arda** (2026-11-21): arda-local's last backup (22:18 on 2026-11-17, when it was stopped) restored into `creative-minecraft-datadir`, replacing the unplayed world arda had started with; the server loaded it. Procedure in `src/manifests/arda/minecraft/README.md` ("Restoring a world from a backup"). Dragonwilds was already on arda (world `CrackDen`).
- **Stopgap retired** (2026-11-21): arda-local's cluster is down and its Windows task "arda-local backups" removed (`./schedule-backups.sh off`). Its backups in `X:/storage/minecraft-backups` are the only copy of the world from before 2026-11-17 outside R2. Never run arda-local again alongside arda: they share the tunnel and the DNS records.

### CI runner (built 2026-11-19)

- `src/manifests/arda/gitlab-runner.yml`: the official chart, Kubernetes executor, `concurrent: 6` (on since 2026-11-23; jobs are pods, so nothing idles), registered with the Multipass VM runner's own `glrt-` token (`ARDA_GITLAB_RUNNER_TOKEN`). One runner in GitLab, two managers, so retiring the VM is switching it off; its repo needs nothing else.
- **Retire the VM** once a real pipeline has run on arda: until then, jobs go to whichever manager asks first.
- **Trade-off**: privileged `docker:dind` job pods, kept because every pipeline already uses it. A job is root on valinor-53, next to the games, and runs whatever any project holding the token pushes. Rootless BuildKit (or `docker buildx` with a remote rootless buildkitd in the namespace) would end that, at the cost of rewriting each pipeline's build steps.
- **No build cache**: each job's image layers are an emptyDir, gone when it ends. The chart can use an S3 cache; an R2 bucket would do.
- Jobs reserve 1 GiB and may use 4 GiB on a 16 GB machine Minecraft mostly fills; two Cypress jobs at once can push the games' pods towards eviction. Watch it in Goldilocks.

### Obsidian (built 2026-11-19)

- `src/manifests/arda/obsidian.yml`: CouchDB 3.5 for the Self-hosted LiveSync plugin at `obsidian-sync.kidd.network` (public through the tunnel, and on the LAN), and linuxserver/obsidian in the browser at `obsidian.kidd.network` (tunnel and LAN, behind the Dex login; linuxserver's own login off). CouchDB's user `obsidian`, password `ARDA_OBSIDIAN_PASSWORD`. Checked: public HTTPS (Cloudflare's certificate), LAN HTTPS (lab CA), writes and reads, CORS for `app://obsidian.md`.
- **One Dex login for arda** (`src/manifests/arda/oauth2-proxy.yml`): forward-auth Middleware `oauth2-proxy-dex`, Dex client `arda`, callback `auth.kidd.network`. Now one proxy per tier, with their own cookies (Users and admins; Sign-in, below). Selkies' websocket through the proxy not yet tried.
- **ainur on the tunnel** (`ainur/sidero-omni/arda-tunnel-cronjob.yaml`): every ainur Ingress annotated `kidd.network/tunnel: "true"` is copied to arda's `cloudflared` namespace, forwarding to ainur's Traefik. Today only Dex and userpage are annotated: Grafana, Headlamp, Argo CD and Omni are LAN only.
- **The tunnel** is on for the friends' sites only (Shared SSO cookie secret & public tunnel, below). Never for an admin site.
- **The admin password** (2026-11-21, reworked 2026-11-23): `bootstrap/netboot/scripts/set-admin-password.sh` sets one password for LLDAP's `admin` (`AINUR_LLDAP_ADMIN_PASSWORD`, the Dex sign-in everywhere) and ntfy's `admin` (`AINUR_DEX_ADMIN_HASH`), and waits for both; Reloader (`src/manifests/ainur/reloader.yml`) restarts what reads them. Set to the real one 2026-11-23.
- **Watch**: Dex is on the internet with no rate limit and no second factor (Security sweep, below).
- **Left to do, in the apps**: install LiveSync in each vault and point it at the server (`couchdb.yaml` has the settings), with end-to-end encryption on. The browser Obsidian's vault can use `http://couchdb.obsidian.svc:5984`.
- **Trade-off**: CouchDB is on the internet with its own admin login, outside Dex: the Obsidian apps can't do an OIDC login. A long random password, and LiveSync's encryption so the server only holds ciphertext. A non-admin CouchDB user per vault would narrow it further.
- **Watch**: at home, phones reach arda's lab-CA certificate, not Cloudflare's. iOS trusts the lab CA once its profile is installed and fully trusted; Android apps ignore user-installed CAs unless the app opts in, so the Obsidian app on Android may refuse to sync on Wi-Fi. If so: a LAN DNS opt-out can't help (the `*.kidd.network` wildcard sends it to ainur), so the way out is a UniFi forward of that one name to public DNS.
- **LAN HTTPS** for all of arda came with it: a `*.kidd.network` certificate from ainur's cert-manager (`ainur/sidero-omni/arda-lan-certificate.yaml`), copied to arda by `arda-bootstrap` hourly and served by arda's Traefik by default. Before, arda's sites answered at home with Traefik's self-signed certificate.
- **Fixed on the way**: external-dns-lan had been crash-looping since `e520a2f` (external-dns 0.23 rejects `!=` in `--annotation-filter`), so no LAN records changed for two hours. Now `notin (false)`.

### More workloads

- Planned on the x86 page, none built: Bitwarden, Crafty, LlamaGPT (Paperless: built, below). Each would be an Argo CD app under `src/manifests/arda` storing its data on Longhorn, with any secrets coming from `.env`.
- After the x86 path is proven and the stopgap retired.
- **Bitwarden**: Vaultwarden is the usual lightweight server; Dex in front like the rest.
- **Media**: built, below.
- **Public utilities** (built 2026-11-22): IT-Tools and CyberChef (`src/manifests/arda/tools.yml`), public with no login, on the public Homepage under Utilities. Checked: both 200 through Cloudflare (public DNS) and on the LAN (lab-CA certificate), IT-Tools' deep links too; listed on `kidd.network`; the blackbox checks pick them up from the tunnel annotation. Other candidates by the same test (all the work in the browser, nothing uploaded, stored or fetched by the server): Excalidraw without its collaboration server, a Gatus status page, BlueMap at its own name, the docs site, a small Kiwix.
- **MeTube and Transmute** (built 2026-11-22; since 2026-11-23 behind the users' sign-in, on the tunnel, and on the users' page too). MeTube 2026.11.22 replaced Elengrab the same evening: Elengrab is a media library (users, watch history, a database), where what's wanted is a yt-dlp page that hands you the file. MeTube has no accounts or database, keeps files and its list a week (`CLEAR_COMPLETED_AFTER`, `DELETE_FILE_ON_TRASHCAN`, and a sidecar deleting anything older), updates yt-dlp nightly (`YTDL_NIGHTLY_UPDATE_TIME`), and refuses private addresses (SSRF). Transmute v2.1.1 runs as 1000 with `ALLOW_UNAUTHENTICATED` (a guest workspace per browser, 30 days); guests need an admin account to exist first, which a postStart hook makes. No login page: an init container patches a script into its `index.html` (from the image's own copy; left unchanged if a new version's page doesn't fit) that opens the browser's guest session before the app starts, and tokens last 30 days (`AUTH_ACCESS_TOKEN_EXPIRE_MINUTES`) instead of 60 minutes. Its session key and admin password are derived from `AINUR_SSO_SECRET`, by `arda-bootstrap`. Neither volume is backed up. Not checked: a download and a conversion.
- **Headlamp names ainur** (2026-11-22): chart 0.36 to 0.46 for `config.inClusterContextName: ainur` (Headlamp 0.40+), so the clusters list shows ainur and arda, not "main". The new chart stopped passing the OIDC scopes from the Secret, so `-oidc-scopes=$(OIDC_SCOPES)` is an extra argument (without `email`, the clusters can't map Dex users). Checked: Headlamp's own cluster list says ainur and arda. Not checked: a Dex sign-in to it.

### Paperless (built 2026-11-19)

- `src/manifests/arda/paperless.yml`, namespace `paperless`: Paperless-ngx 3.5.1 at `paperless.kidd.network` (tunnel and LAN, admin Homepage), one pod with a Valkey 9.0 broker and a Samba sidecar (`servercontainers/samba`, smbd only). SQLite in `paperless-data` (5 Gi), documents in `paperless-media` (20 Gi), both backed up by VolSync (checked: their `-volsync` Secrets, ReplicationSources and first backup pods appeared); `paperless-consume` (2 Gi) opted out, since files only pass through it.
- **Memory**: before, arda was at 81% used (12.3 GiB) with 79% requested. Paperless requests 640 MiB and is limited to 1.5 GiB. One task worker with two OCR threads and one web worker; it sits at ~570 MiB idle and ~700 MiB just after OCR. Left out for memory: Postgres (SQLite does for one household), Tika and Gotenberg (only Office files and `.eml` bodies need them). Add them with the second ProDesk.
- **Logins**: Dex client `paperless` (confidential, `AINUR_OIDC_CLIENT_SECRET`, PKCE too), through django-allauth. `PAPERLESS_SOCIAL_AUTO_SIGNUP`. Who is a superuser comes from LLDAP's `admins` group at each sign-in (Users and admins, below); the `paperless-setup` CronJob no longer promotes anyone. Local superuser `paperless` / `ARDA_PAPERLESS_ADMIN_PASSWORD` (generated). Checked: real Dex sign-ins, an admin's and a `users`-only one (Users and admins, below).
- **Lab CA vs Python 3.14**: Paperless's Python refuses the lab CA ("CA cert does not include key usage extension", `VERIFY_X509_STRICT`, default since 3.13). Worked around in `paperless/sitecustomize.py`, which drops only that flag and only for `*.kidd.network` hosts (an expired public cert is still refused: checked), and the same in `homeassistant/sitecustomize.py` (2026-11-21), which also patches `wrap_bio`, the path asyncio and aiohttp take; Paperless's only covers `wrap_socket`. **The real fix**: re-issue the lab CA with `keyUsage = critical, keyCertSign, cRLSign` in `gen-lab-certs.sh`, keeping the same key so nothing that trusts it breaks. Every Python 3.13+ client of a lab-CA site will hit this.
- **Ingestion, checked**: an image-only PDF through the API and another dropped on `\\192.168.1.58\scan` (user `scanner`, `ARDA_PAPERLESS_SCANNER_PASSWORD`, SMB3) were both OCR'd and found by `?query=`; the share empties itself; a wrong password gets `NT_STATUS_LOGON_FAILURE`. SMB is LAN only: the LoadBalancer has no `kidd.network/port-forward` and no external-dns hostname.
- **Mail: off**, waiting for a mailbox. Set `ARDA_PAPERLESS_MAIL_HOST`/`_USER`/`_PASSWORD` (optional `_PORT`, `_FOLDER`), rebuild the served secrets, and the CronJob creates account and rule `inbox`: attachments only, mark read, 30 days. Untested against a real mailbox; the model fields and enums it uses were checked in the running 3.5.1.
- **Scanner**: scan-to-email suits most home scanners better than SMB (universal, works away from home, and many cheap devices only speak SMB1, which Samba refuses). The share is ready for one that does SMB2/3.
- **Left to do, in the UIs**: Paperless Mobile / Swift Paperless on the phone (server `https://paperless.kidd.network`; user `paperless` or a Dex user's password or API token from *My Profile*); tags, correspondents and document types as paperwork arrives. The two test documents (`api-test`, `smb-test`) can be deleted.
- **Watch**: the data and media volumes are backed up separately, minutes apart. A restore can find a document row without its file or the reverse, and `document_sanity_checker` reports it. For a guaranteed-consistent copy, a nightly `document_exporter` into a backed-up volume would do; not added (memory and space).

### Media (built 2026-11-19)

- `src/manifests/arda/media.yml`, namespace `media`, all LAN only: Seerr 3.5 (`seerr`), Prowlarr 3.0, Sonarr 4.0, Radarr 7.0, Bazarr 1.6, qBittorrent 5.1 + gluetun 3.41, Jellyfin 10.11, Plex (each at `<name>.kidd.network`, on the admin Homepage under Media). Seerr is the merged Overseerr + Jellyseerr (2026), serving Plex and Jellyfin both.
- Dex (`oauth2-proxy-dex`) in front of Prowlarr, Sonarr, Radarr, Bazarr and qBittorrent; the arrs' auth is `External`, Bazarr's none, qBittorrent's skipped for `10.244.0.0/16`, with a NetworkPolicy so only its own clients reach it (2026-11-23). Seerr, Jellyfin and Plex: their own users. Checked: each Dex-guarded host 302s to Dex's login; Seerr's and Jellyfin's first-run wizards answer; LAN DNS and lab-CA HTTPS for all.
- **Storage**: PVC `media`, 200 GiB Longhorn, `kidd.network/backup: "false"` (checked: no VolSync objects for it), TRaSH layout `/data/torrents/{tv,movies}` + `/data/media/{tv,movies}`, mounted at `/data` everywhere. Longhorn had 957 GB free. Each `*-config` volume is backed up as usual. **ReadWriteMany since 2026-11-24**: RWO had every media pod on whichever node the volume was attached to (valinor-54); now Longhorn shares it over NFS (a share-manager pod), its two replicas on the 1 TB disks of valinor-53 and -56, and the media apps go on any node but the control plane. Moved by copy (rsync -aH, hardlinks kept: 190 files, 11.5 GB, 22 hardlinked) to a temporary volume and back into a new `media` claim; needed Longhorn over-provisioning at 200% (claims had reached 70% of a disk at under 10% used). NFS doesn't take SELinux xattrs (rsync -X fails). **Watching folders stopped working with it**: a file written from another node raises no inotify event, so Jellyfin scans its libraries every 30 minutes (its trigger file, set by an init container) and Grimmory syncs every 15 (set by the wiring job). Better for films and series: Sonarr and Radarr telling Jellyfin on import (Connect → Jellyfin), which wants a Jellyfin API key, made after its wizard. **The NAS**: an NFS PersistentVolume pre-bound to `media` (claimRef), same paths; and drop the Longhorn one, whose three replicas would want 600 GB once three nodes exist.
- **Wiring** (`media/wiring.mjs`, CronJob every 15 min, idempotent): API keys derived by `arda-bootstrap` from `ARDA_MEDIA_API_SECRET` (generated, in `.env`). Done and checked: Prowlarr → Sonarr and Radarr (applications), root folders in Sonarr and Radarr, Bazarr → Sonarr and Radarr (its `config.yaml`, written by a yq init container; Bazarr reports both versions). Waiting: Seerr → Sonarr/Radarr (after its wizard).
- **Left to do, in the UIs**: Jellyfin's wizard (admin user; libraries `/data/media/tv`, `/data/media/movies`); Seerr's wizard (sign in with Jellyfin); indexers in Prowlarr; Bazarr's languages profile and subtitle providers (it warns "Missing languages profile" until then).
- **qBittorrent is up** (2026-11-21), over Mullvad (`ARDA_MULLVAD_PRIVATE_KEY`, `ARDA_MULLVAD_ADDRESSES` in `.env`; one key and address for every server). Checked from its own container: `am.i.mullvad.net` says `mullvad_exit_ip: true`, not the home address. **Kill switch checked**: with gluetun's `tun0` deleted, requests by IP, by name and to the home address all timed out; gluetun rebuilt the tunnel in ~70 s. Sonarr and Radarr have it as their download client (the wiring job, once it was up), and both pass their test. `ARDA_MULLVAD_COUNTRY=Ireland`: exits in Dublin (re-checked, kill switch too). That needed gluetun's main build (2026-11-20, pinned by digest): release v3.41.3 (July) has stale Mullvad server data, with old keys and addresses for the Irish servers, so it never connected; back to a release tag once a newer one is out. gluetun tries a server's IPv6 endpoint first and fails (no IPv6 in the pods) before IPv4: a few seconds per connect. Mullvad has no port forwarding: no incoming peers.
- **The Internet Archive as an indexer** (2026-11-23, `wiring.mjs`): public domain and openly licensed films only. First library: Big Buck Bunny, A Trip to the Moon, The Great Train Robbery, Caligari, Nosferatu, Battleship Potemkin (all public domain in the UK, makers dead before 1955), and Pioneer One (CC) in Sonarr. **Watch**: archive.org names carry no quality, so Radarr calls them "Unknown", which no profile accepts; a search alone grabbed only the oddly named ones (a trailer, a 41 GB 4K rip, a DVD image). The five films were picked by hand from the interactive search. Allowing Unknown in a profile, with a size cap, would let searches work alone. Pioneer One: only E1 is named so Sonarr can match it; E2-E6 (archive.org "PIONEER ONE Ep. N ...") were added to qBittorrent by hand and imported by hand (Sonarr's ManualImport command with each file's episode; its folder lookup ignores the folder when given a series). All six in Plex 2026-11-24. Sonarr and Radarr rename to the standard format since then (the wiring job), so Plex matches whatever a download was called. Plex follows the disk since 2026-11-23 (`plex.yaml` settings init), so imports appear by themselves. Downloads are slow (archive.org's web seed, ~100 kB/s each). **Prowlarr searches through Mullvad too** (2026-11-23): gluetun's HTTP proxy on 8888, reachable only by Prowlarr (NetworkPolicy), set by the wiring job; checked: proxied requests exit in Dublin, Radarr can't use it, a search returns results. Radarr's and Sonarr's metadata lookups (TMDB, TVDB) still go direct.
- **Plex is on** (2026-11-19, once valinor-54 joined), **claimed 2026-11-23** (identity says `claimed="1"`; the one-off `plex` Secret deleted after). How: it needs a claim token from plex.tv/claim, which lasts 4 minutes, too short for `.env` → VM → arda, so it goes straight into a `plex` Secret in `media` and Plex is restarted (`plex.yaml`). Checked: `http://192.168.1.58:32400/identity` answers `claimed="0"`.
- **Four nodes now**: valinor-53 (control plane) and workers valinor-54, -55, -56, all HP ProDesk 400 G4 DM, i5-8500T, 16 GiB, BIOS Q23 02.06.00 (2019).
- **Quick Sync, on the workers** (`systemExtensions` of the Workers set in Omni's cluster template, with the node label `kidd.network/gpu: intel` from a `KubeNodeConfig` patch). Checked on valinor-54: 15 minutes idle, then 5 minutes of back-to-back 1080p QSV encodes (91 runs, jellyfin-ffmpeg, as uid 1000), no GPU hang; then 42 hours up. Jellyfin and Plex ask for `devic.es/dri` (the generic device plugin's current resource domain; older builds said `squat.ai`); Jellyfin's `encoding.xml` is set to QSV while it's still at the defaults. The media volume's pods all require a `kidd.network/gpu` node (a preference lost to the scheduler's other scores), so with no GPU worker up the media apps wait. Plex uses the GPU only with a Plex Pass.
- **i915 reset some machines, until two kernel arguments.** valinor-53 (2026-11-19, as the control plane: arda down ~35 min, rolled back) and valinor-55 (2026-11-21, a worker) hard-reset about two minutes into every boot with i915, nothing logged, nothing in pstore; valinor-54 and -56, same model, BIOS (Q23 02.06.00) and image, ran it for days. With `i915.enable_dc=0 intel_iommu=igfx_off` (no display power-saving states; the GPU outside VT-d), valinor-55 stayed up and passed the same 5-minute QSV load (128 runs). Which of the two does it is not known. **Now on every machine**: the `arda-disks` CronJob applies `KERNEL_ARGS` (in its spec) as each `talos-default` machine's Omni `KernelArgs`, discovered, not listed, because Omni refuses kernel args in a template whose machine sets use machine classes (its validator accepts them; the sync fails). Rolled out 2026-11-21: one reboot each, all four up 10+ minutes after. **valinor-53 has i915 again** (2026-11-21, with the args): up 15+ minutes past where it used to reset, then 5 minutes of QSV load (124 runs). So all four nodes have the GPU. The control plane isn't labelled `kidd.network/gpu` (the label is a Workers patch), so the media apps stay on the workers, away from its ~85% memory.
- **Letterboxd watchlist into Radarr** (2026-11-23, `media/letterboxd.yaml`): screeny05's letterboxd-list-radarr (by digest; Valkey cache beside it, in the cluster only), and the wiring job adds `ARDA_LETTERBOXD_USER`'s watchlist to Radarr as a list (HD 720p/1080p, every 12 hours). Not searched on add: the watchlist holds hundreds, so Radarr's feed check grabs films as releases appear, and a film can be searched from its page. **Running** (2026-11-23): 446 films in Radarr, monitored. With only the Internet Archive as an indexer, few of them will ever be found; that waits on another indexer in Prowlarr. **Watch**: Letterboxd changed its terms in January 2026 and blocks such scrapers with Cloudflare; watchlists and plain lists still work, director, collection and popular pages get 403 (the project's issues #64, #67). If watchlists go too, the fallback is Letterboxd's own data export (watchlist.csv) imported by hand. Not bypassing Cloudflare (FlareSolverr).
- **Upgrades on Longhorn**: its default `node-drain-policy` (`block-if-contains-last-replica`) blocked the first i915 upgrade on one node: Omni cordoned valinor-53, evicted everything, and hung at the instance manager's PDB. Now `always-allow` (`longhorn/values.yaml`). With four nodes holding replicas, `block-if-contains-last-replica` may be safe again.
- **Remote streaming**: LAN only. A port forward (`kidd.network/port-forward: "true"` on a LoadBalancer Service) for Plex's 32400 or Jellyfin would allow it; the tunnel can't carry video under Cloudflare's terms.
- **Stremio fallback**: a self-hosted addon for when the hosted Torrentio is down. Not `torrentio-scraper` (crawlers and a database); Jackettio or Comet, which query the same Prowlarr on demand, one small container. Without debrid, Stremio streams torrents from the home IP.

### Books, comics, manga, audiobooks (built 2026-11-24)

- **Chosen** (2026-11-24, after weighing Kavita, Komga, Grimmory, Bookkeeprr, Shelfmark, Kapowarr, Suwayomi, Readarr's forks): one request portal (Seerr), one reading portal (Grimmory), fetchers as back office. In `media/`, LAN only:
  - **Chaptarr 0.9** (`chaptarr.kidd.network`, behind `oauth2-proxy-dex`, auth `External`): books and audiobooks, a Readarr fork (Readarr is archived). Root folders `/data/media/books` (ebook) and `/data/media/audiobooks`, qBittorrent categories `books`/`audiobooks`, all by the wiring job. **Prowlarr's Readarr app sync fails against it** (Chaptarr#84, 500 on `/indexer/schema`), so the wiring job adds Prowlarr's book indexers (7000s, 3030) to it as Torznab feeds instead; only the Internet Archive so far. 2 GiB: adding a book loads the author's whole catalogue (5,648 books for Jane Austen) and ran past 1 GiB.
  - **Comicarr 0.65** (`comicarr.kidd.network`): comics and manga, Mylar3's successor. **Two logins**: it has no external-auth mode, so after Dex comes its own (user `admin`, password `comicarr-password` in the `media` Secret). Its login, API key, qBittorrent (category `comics`), Prowlarr and folders are seeded into `config.ini` by an init container (the first-run page wants a token from the log). **Comics search needs a ComicVine key** (`ARDA_COMICVINE_API_KEY`, optional, unset): without it only manga (MangaDex) search works. Its MangaDex chapter downloads go out the home line, not Mullvad. Its API key covers only read-only routes; adding series needs a session.
  - **Grimmory 3.5** (`grimmory.kidd.network`, behind `oauth2-proxy-dex-users`, on both signed-in Homepages): reads all four, with MariaDB 11.4 (`grimmory-db`). No login of its own: it trusts oauth2-proxy's `X-Auth-Request-*` headers (the `dex-users` Middleware now passes `Preferred-Username` and `Groups` too); `admins` become Grimmory admins at first sign-in. A NetworkPolicy lets in only Traefik and the wiring job, which makes the four libraries.
- **Requests for books and comics: none yet.** Chosen: one request portal (Seerr), but Seerr has only films and series. A fork of it (`andrewiankidd/seerr`, 2026-11-24: Books and Comics & Manga pages beside Seerr's own, settings written by an init container, its own request table) was dropped the same day for not being at parity (no settings page, no approval, no availability) and arda is back on upstream Seerr. Seerr has no provider abstraction: films and series are hardcoded in about 2,000 places across 149 files, only `ServarrBase` (status, profiles, root folders, queue, tags) is shared, which is why its Lidarr work has taken years. jabloink's book fork (Seerr#1918, closed as too large; still active) puts audiobooks in the 4K slot and needs Hardcover, and has no comics. If done again: a provider layer (search and details, request options, send, availability, a settings descriptor) beside films and series, Chaptarr (ebook and audiobook as a request field) and Comicarr as its first providers; manga later.
- **Upstream later**: Seerr issue #134 (books, open since 2022) waits on its Lidarr work. **Seerr bans AI-driven contributions** (CONTRIBUTING.md: AI only as an aid, the design and code the contributor's own, disclosed; large features need a Discussion first), so anything upstream is the user's own work, not this lab's code. Grimmory#338 (manga reading direction not remembered) is a small first contribution; Grimmory requires AI disclosure.
- **Memory on the workers**: with ReadWriteMany the media pods spread over valinor-54, -55 and -56 instead of sharing one node.
- **Open**: Grimmory's default libraries and permissions for non-admin users (set under its Authentication settings; until then a family member signs in to an empty Grimmory). Comicarr's double login (a PR adding an external-auth mode would fix it). Whether Chaptarr's Prowlarr sync works after Chaptarr#84.

### Home Assistant and a local assistant (the end goal)

- Replace Google Nest and the Hue cloud with Home Assistant plus a local LLM voice assistant: Whisper (speech to text), Piper (text to speech), Ollama behind Home Assistant's Assist, and Home Assistant voice satellites where the Nest speakers are. All local, so it fits the offline rule.
- **Home Assistant is up** (2026-11-19, `src/manifests/arda/homeassistant.yml`): the container image 2026.11.2 at `homeassistant.kidd.network`, LAN only, its own login, `/config` on Longhorn (VolSync's first backup ran), `configuration.yaml` from Git. On the host network in a privileged namespace; from the pod, mDNS sees the Hue Bridge, seven Google Cast devices (the Nest speakers and Chromecasts) and eight Matter devices.
- **No manual setup, Dex login** (2026-11-21): a CronJob (now `homeassistant/setup.py`) does onboarding through the API, owner `admin` with `ARDA_HOMEASSISTANT_PASSWORD`; core settings are in `configuration.yaml`. hass-oidc-auth 1.2.1 (pinned, sha256-checked, fetched once into the volume) gives "Log in with Dex" through a public PKCE Dex client; Dex `admin` links to the owner. Checked without a browser: onboarding finished, `/auth/providers` lists OIDC and local, the redirect reaches Dex's login page with the right client and callback, the Android app's welcome shows a device code, and the owner's local login succeeds. Not checked: a full Dex sign-in (needs the Dex password typed into Dex), and the real companion app.
  - HTTP settings left YAML in 2026.11: Home Assistant now migrates `http:` once into `.storage/http` as a trial that reverts after 5 minutes unless confirmed in the UI, then ignores YAML (YAML support ends in 2027.2). The trusted proxies from 2026-11-19 had silently reverted. The Deployment now writes `http.json` into the store as the confirmed config at every start; if the store's format changes (version 3 today), revisit.
  - Trusted proxies are arda's pods and the whole LAN /24: Home Assistant is on the host network, so Traefik on another node arrives masqueraded as its node's address. Any LAN device could forge X-Forwarded-For, which only affects ip_ban and the logs; narrower once the Lab VLAN exists.
  - Who may sign in through Dex is LLDAP's `admins` group (`roles`, 2026-11-23); anyone else is refused.
- **Voice, Matter and Cast, set up by the same CronJob** (2026-11-21; `onboard.py` became `homeassistant/setup.py`): Whisper (`wyoming-whisper` 3.9.1, model `auto`, which for English is NVIDIA's Parakeet through sherpa-onnx) and Piper (`en_GB-alba-medium`) as their own Deployments; Ollama 0.40.17 with `qwen3:4b-instruct` (Home Assistant's suggested model), pulled at start into its volume; the Matter Server (`matterjs-server` 1.6.0, the Python server's successor) as a sidecar in Home Assistant's pod, on localhost. The CronJob adds the Wyoming, Ollama, Matter and Cast integrations if missing (confirming Cast's discovered flow), an Ollama conversation agent allowed to control the house, and a preferred **"Local"** pipeline: Whisper, Home Assistant's own intents first, then Ollama, then Piper. Optional `ARDA_HOMEASSISTANT_LATITUDE`/`_LONGITUDE` set the home's location (set in .env, applied 2026-11-21).
  - Checked end to end without a browser: Piper speaks a sentence in 0.6 s and Whisper transcribes it back exactly in 0.3 s; through the Local pipeline, "What time is it?" is answered by Home Assistant's intents in 0.2 s, and a general question goes to Ollama and is answered (with speech) in 3-5 s once warm. The first LLM answer after Ollama started took 89 s: reading Home Assistant's ~2,900-token prompt (exposed entities, tools) at CPU speed, cached afterwards. Ollama holds ~4 GB and uses ~3 cores while answering.
  - Wyoming's config flow doesn't refuse a second entry for the same server, so the CronJob's first version added duplicates; it now asks each server its name (which Home Assistant uses as the entry's title) and removes any duplicate.
  - The Matter Server logs that it can't send mDNS on the node's veth interfaces (it uses every interface on the host network). Harmless; `PRIMARY_INTERFACE` would quiet it, but the NIC's name may differ per node.

Next, in order. What's left needs a person or hardware:

- **Hue**: discovered, waiting in Settings > Devices & services as "Discovered". Pairing needs the bridge's button pressed within 30 s of confirming, so it can't be a CronJob step. Works locally while the bridge stays; the Zigbee coordinator below replaces it.
- **The Matter devices** (eight, currently Google Home's): Matter allows several controllers, so share each from the Google Home app ("Linked Matter apps & services" gives a pairing code) and commission it in Home Assistant with that code. One phone step per device; the Matter Server keeps the fabric in its own volume (`matter-data`, never pruned).
- **Voice satellites where the Nest speakers are**: Home Assistant Voice PE (or ESP32-S3 boxes with ESPHome) use the Local pipeline as it is; the wake word runs on the device (microWakeWord), so no openWakeWord server unless a satellite can't.
- **A faster LLM answer**: 4 tokens/s on a ProDesk's CPU. Before any GPU: a smaller model (`qwen3:1.7b`), fewer exposed entities (a shorter prompt), or Ollama on the iGPU now that i915 is loaded (Ollama's Vulkan backend; not tried).
- **Away from home**: the companion app needs Home Assistant reachable. The tunnel (`kidd.network/tunnel: "true"` on its Ingress) is one line, but puts Home Assistant's login on the internet; ip_ban is on (10 failed logins). Off until wanted. Cloudflare Access in front would break the app, as a Dex forward-auth would. The Dex login away from home also needs Dex reachable through the tunnel; the local login doesn't.
- **Bluetooth** isn't available (no adapter passed in, and arda's ProDesk may have none); ESPHome Bluetooth proxies would cover it over the network.
- **The IoT VLAN**: once devices move off the Lab VLAN, mDNS and SSDP won't cross by themselves; the UniFi gateway's mDNS reflector, or Home Assistant given a leg on that VLAN.
- **Zigbee over the network, not USB**: a PoE Ethernet coordinator (SLZB-06-style) lets Home Assistant run on arda without being pinned to the node with the dongle. Hue bulbs are Zigbee and pair to it directly, so the bridge and its cloud go.
- **The LLM is on CPU** (built 2026-11-21, above). GPUs are out of budget. Home Assistant's own intent matching handles plain commands instantly with no LLM; a small quantized model (3B-8B, Ollama) on a ProDesk handles the rest in seconds. A GPU box later changes nothing else. Supersedes LlamaGPT.
- On the Lab VLAN, its IoT devices on IoT. Whatever the household uses has to keep working mid-rebuild, so keep a manual fallback (switches, the Hue app) until it has earned trust.
- If the Nest setup includes cameras or a doorbell: UniFi Protect records locally and Home Assistant integrates with it.

### Users and admins: tiers (started 2026-11-23)

The plan: kidd.network for anyone; user.kidd.network (any Dex user) for what friends and family get (Plex, Jellyfin, Seerr, MeTube, Transmute, utilities); admin.kidd.network (the `admins` group) for everything. In four steps: (1) LLDAP and groups, (2) the admin apps locked to `admins`, (3) the user apps opened to `users`, (4) the three Homepages.

- **1. LLDAP and groups (done 2026-11-23)**: `src/manifests/ainur/dex/lldap.yaml`. LLDAP v0.6.3 on ainur (`ainur-dex`, valar-50's NVMe), its page at lldap.kidd.network (LAN): people, groups (`admins`, `users`) and passwords, people changing their own. A bootstrap CronJob keeps the groups, LLDAP's admin (`admin@kidd.network`) in both, and a read-only `dex` account. Nightly restic backups to R2 (`arda-backups/lldap`, the `ARDA_BACKUP_*` keys read from `arda-secrets` through a Role for that one Secret); an init container restores the latest when the database is missing. Dex has an LDAP connector ("KiddNet"; sign in with the email since 2026-11-23); the static admin beside it was removed the same day (below). Dex pinned to v2.41.1: 2.41.0's LDAP connector dials `:389` whatever the host (it builds `ldap://://host`). Checked: the bootstrap made the groups; the `dex` account lists them; a sign-in through Dex as `admin` gave an ID token with `groups: [admins, lldap_admin, users]`; the first backup is in R2. Not checked: a restore onto an empty volume. Four new `AINUR_LLDAP_*` values in `.env`.
- **2. The admin apps locked to `admins` (done 2026-11-23)**. arda's oauth2-proxy (every site behind `oauth2-proxy-dex`) and Headlamp's ask Dex for `groups` and pass only `admins` (`--allowed-group`; new cookie names, `_kidd_admins` and `_headlamp_admins`, since a session from before the groups would only ever 403). Grafana: Admin for `admins` or the static admin's email, anyone else turned away (`role_attribute_strict`). Argo CD: `g, admins, role:admin` beside the email line (user-data, applied live on valar-50); anyone else signs in to an empty list. Paperless: its own group sync at each sign-in (`PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP`/`_STAFF_GROUP`), anyone else a plain user who sees nothing; the setup job no longer promotes. Home Assistant: `roles` admin and user both `admins`, anyone else refused. Unchanged, already the admin's alone by email: Omni (its user list) and Kubernetes (the ClusterRoleBinding). Checked with a throwaway LLDAP user in `users` only, then deleted, through real sign-ins: Grafana refused, Argo CD empty, Headlamp and Sonarr 403, Home Assistant "not in the correct group", Paperless documents 403; LLDAP's `admin` got into every one.
  - **Dex's static admin, removed** (later the same day): it carried no groups (Dex's static passwords can't), so every gated page refused it, and it was the second button on Dex's page that led there. Dex is LLDAP only now (`enablePasswordDB: false`), and with one connector it goes straight to the KiddNet form. You are LLDAP's `admin`: `set-admin-password.sh` writes `AINUR_LLDAP_ADMIN_PASSWORD` (LLDAP resets admin to it at every start, `LLDAP_FORCE_LDAP_USER_PASS_RESET=always`) beside ntfy's hash, and waits for both; change it there, not on LLDAP's page. Grafana and Argo CD dropped the email special case. With LLDAP down there is no Dex login at all: Home Assistant and Paperless keep their own (`admin`, `paperless`), and kubectl on valar-50 is the rest. Checked: Dex's `/auth` 302s straight to `/auth/lldap`; LLDAP's `admin` into Grafana and the admin page.
  - **Your Paperless user, moved** (a one-off): it was linked to the static admin's Dex identity, so LLDAP's `admin` (same email) got allauth's sign-up form. Its link now points at LLDAP's `admin` (Dex subject `CgVhZG1pbhIFbGxkYXA`). A rebuilt Paperless has no such user, so nothing to repeat.
- **3. The user apps opened to `users` (done 2026-11-23)**. A second oauth2-proxy on arda (`oauth2-proxy/users.yaml`), under `/oauth2-users` on auth.kidd.network with its own cookie (`_kidd_users`), lets `users` and `admins` through, as the Middleware `oauth2-proxy-dex-users`. MeTube and Transmute are on it; Plex, Jellyfin and Seerr keep their own logins (a friend needs a Plex or Jellyfin account, Seerr signing in with those). Checked: LLDAP's `admin` through to MeTube, and still to Sonarr on the admins' proxy.
- **4. Three Homepages (done 2026-11-23)**: `homepage-public` (kidd.network, no login), `homepage-users` (userpage.kidd.network, behind `oauth2-proxy-users`: `users` and `admins`, on the tunnel), `homepage` (admin.kidd.network, LAN, behind `oauth2-proxy-admin`, admins only, no login of its own and a Sign out bookmark). Which page lists what is Homepage's own instance filter: no `gethomepage.dev/instance` for every page, `instance: admin` (was `private`, renamed in all 22 files) for the admin page only, plus `gethomepage.dev/instance.users: "true"` for the users' page too (MeTube, Transmute, Seerr); the arda mirror copies every `gethomepage.dev/*` key, so arda's apps need nothing more. Every page has Areas (links to the other two) and the node cards; the header logo goes to kidd.network on every page; the public page has External (andrewkidd.co.uk, tiltedcartridge.co.uk). Checked: the admin page through its proxy as `admin` (services and bookmark), the public page's groups, the users' page's list from the annotations. userpage's sign-in checked since, through its proxy.
  - **Add friends now**: in LLDAP (lldap.kidd.network), a user in `users`; they sign in at userpage.kidd.network.

### ainur's k3s crashed on its datastore (2026-11-23)

- At 08:36:58 k3s on valar-50 exited: `level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"`, after kine's SQLite reads had been timing out (`DeadlineExceeded`). It came straight back (systemd restart; `NRestarts=2`, so once before too). The trigger was a hard refresh of every Argo CD app at once, during a large sync. Watch: SQLite kine on the SD card is the control plane's weak point; don't mass-refresh, and look at k3s's embedded etcd in place of SQLite if it recurs.

### Sign-in: fewer prompts, no consent page, Dex keeps state (2026-11-23)

- **One sign-in per tier.** Every oauth2-proxy shares its tier's cookie on `.kidd.network`: `_kidd_admins` (arda's admin sites, Headlamp, the admin page) and `_kidd_users` (MeTube, Transmute, and userpage, now behind a proxy like the admin page, with a Sign out bookmark). Not one cookie for both: oauth2-proxy deletes a session that fails its group check, so a shared one signed a friend out of everything at the first admin link. Grafana, Argo CD, Home Assistant, Paperless and Omni keep their own Dex logins, so they ask once each; Dex has no browser session of its own (dexidp/dex#4560, not released).
- **No "Grant access" page**: `oauth2.skipApprovalScreen` in Dex, and `--approval-prompt=auto` on every proxy (oauth2-proxy otherwise asks Dex to force it).
- **Dex's state in Kubernetes** (its CRDs on ainur): signing keys and refresh tokens survive a restart, which Reloader causes on any `ainur-secrets` change. Not backed up: lost, everyone signs in again.
- **Checked** with a throwaway `users`-only account (deleted): one prompt for MeTube, Transmute and userpage; refused at the admin page and Sonarr, and still signed in to MeTube after; `admin` one prompt for Sonarr, Radarr, Headlamp and the admin page, across both clusters.

### Shared SSO cookie secret & public tunnel (2026-11-23)

- Every oauth2-proxy's cookie key, and Transmute's session key and admin password, derive from `AINUR_SSO_SECRET`, a dedicated random value in `.env` separate from `AINUR_OIDC_CLIENT_SECRET` (ainur reads it from `ainur-secrets` and `headlamp-oidc`; arda's proxies from the `dex` Secret's `cookie-seed`, written by `arda-bootstrap`). Checked: cross-cluster sign-in works on the shared key.
- **The tunnel for friends: on** (2026-11-23): `dex` and `auth` (the sign-in), `userpage`, MeTube and Transmute, and `arda-tunnel` unsuspended (it publishes only Dex and userpage of ainur's). Checked from the internet side (names pinned to Cloudflare): a `users`-only account signs in once at MeTube and reaches Transmute and userpage without another prompt. No admin site has a public name. Dex on the internet has no rate limit; Cloudflare's in front.

### Security sweep (2026-11-23)

Done: dedicated `AINUR_SSO_SECRET` for SSO cookie derivation; Dex loads only its two secrets instead of all of `ainur-secrets`; the apps' copies of `ainur-secrets` no longer carry the k3s join tokens (netboot's keeps them).

Still open, from a read of every manifest, most serious first:

- **High: the secrets push trusts any SSH host.** `scripts/push-secrets.sh` sends every AINUR_*/ARDA_* value to whatever answers on a Pi's address, every 30 s, with `StrictHostKeyChecking=no`. Check `awaiting-push` in a first call carrying nothing, and pin host keys.
- **High: any x86 machine on the LAN joins arda.** The join token is in the schematic served over plain HTTP, and `arda-disks` labels every unallocated machine a worker, which then runs pods with their Secrets. Allocate only machines approved by a label, or matched to UniFi DHCP reservations.
- **High: Omni jobs run an unverified `omnictl` with the automation key**, from a shared writable PVC, and take `system:masters` kubeconfigs where a narrow role would do (unifi, tunnel, homepage jobs). Checksum the binary; per-job groups and Omni service accounts with Reader/Operator.
- **High: the netboot builder** is `:latest`, `Always` pulled, privileged with `/dev`, and loads all of `ainur-secrets`; it needs only `AINUR_PUSH_PUBKEY`. Pin by digest, pass that one key.
- ~~**High: qBittorrent skips its login for arda's whole pod network**~~ **Fixed** (2026-11-23) with a NetworkPolicy: only Sonarr, Radarr, the exporter, the wiring job and Traefik reach it. arda's flannel ignored NetworkPolicies, so kube-router now runs there in firewall-only mode (`arda/network-policy.yml`, as k3s does), and arda can take policies from here on: the next candidates are CouchDB, LLDAP and the CI namespace. Checked: Sonarr, Radarr, Traefik and the exporter get through; the MeTube pod and fresh pods are refused; the routed sites still answer. A new pod is let in ~2 s after it starts (kube-router's sync), so `wiring.mjs` retries its up-checks.
- **Medium: arda checks no certificate on the hop to ainur** (`cloudflared/ainur-homepage.yaml`, `insecureSkipVerify`), which every internet Dex sign-in now crosses. The lab CA is on arda already; a ServersTransport with it and per-host server names.
- **Medium: the UniFi job's API calls skip TLS checks** (`curl -k`) with a key that makes port forwards. Pin the controller's certificate.
- **Medium: LLDAP's backup Role can read all of `arda-secrets`**, and its token is mounted in the LAN-facing container. A Secret of its own for the backup keys; no automounted token.
- **Medium: CouchDB's one login is its server admin, on the internet** (`/_utils`, `/_config` reachable). A non-admin LiveSync user, tunnel paths limited to the vault databases.
- **Medium: internet logins with no throttle or second factor**: Dex, Paperless's local `paperless` superuser. Cloudflare rate limits on `dex/auth/*` and `paperless/accounts/login`; TOTP on `paperless`.
- **Medium: kube-vip runs as cluster-admin** (privileged, host network); its documented ClusterRole would do. **CI jobs are privileged on any arda node**, the control plane included: a tainted CI node, and a protected runner.
- **Low**: Argo CD projects allow any source repo, and the arda project any cluster-scoped kind on ainur; `generic-device-plugin` is `:latest` and privileged; ainur's API server takes the email claim unprefixed (LLDAP's unique emails stop a takeover today); weak defaults in examples (`my-cluster-token` in a guide, `raspberry` in the RaspiOS example config).
- Fine as they are: Goldilocks' `--kubelet-insecure-tls` (Talos), Dex's plain LDAP to LLDAP in-cluster, Argo CD's `--insecure` behind Traefik.

### Dex themed (2026-11-23)

- A `kiddnet` theme (`ainur/dex/theme.yaml`): Tokyo Night Storm's colours (`#222436`, as the Homepages), the AK logo in the bar and as the favicon, the issuer shown as KiddNet. Theme files only, Dex's templates untouched. Needs `frontend.dir: /srv/dex/web`: without it Dex v2.41 serves its built-in copy of the web files and the mounted theme 404s, while still starting. Checked: the theme's files served with the right types, and a headless screenshot of the live login page. Reloader restarts Dex on a theme change.
- **The KiddNet logo** (2026-11-23): the AK mark over a globe of meridians, parallels and coastlines (Natural Earth 1:110m, public domain), centred off West Africa. `docs/brand/make-logo.py` draws `docs/public/brand/kiddnet-logo.svg` and `kiddnet-globe.svg`. It heads both Homepages and Dex's login bar; the Homepage footer mark and the favicon stay the plain AK, as the globe is fuzz that small. Checked with headless screenshots of the Dex login page and kidd.network.

### Every arda service on a Homepage (2026-11-22)

- The arda-homepage mirror copies annotated Services as well as Ingresses (host from external-dns's hostname), so Dragonwilds, which has only a UDP port, is on the public Homepage under Games, linking to the game's site. Obsidian sync's CouchDB admin page is on the private one.
- Longhorn's UI and Goldilocks' dashboard had no page at all (Goldilocks was port-forward only). Now `longhorn` and `goldilocks.kidd.network`, LAN only, behind the Dex login (forward-auth), on the admin Homepage; both 302 to Dex.
- **One Argo CD for both clusters** (2026-11-22): ainur's deploys arda's apps; arda's own Argo CD (and its page and Dex login, built earlier the same day) is gone. ainur's has an `arda` project and root app (user-data: `24-arda-apps.yaml`), and every app in `src/manifests/arda` deploys to the cluster named `arda`, which `arda-bootstrap` registers last, after the apps' Secrets: an `argocd-manager` service account with cluster-admin on arda, its long-lived token, and arda's API address (the `kubernetes` EndpointSlice, `192.168.1.53:6443`) and CA, straight to arda's API rather than through Omni's proxy. The Application health check the sync waves wait on is patched into ainur's `argocd-cm` by `arda-bootstrap` (a Helm upgrade of ainur's Argo CD drops it until the next run; it applies to ainur's own root apps too). arda's `generic-device-plugin` app is `arda-generic-device-plugin`: ainur has its own of that name in the same Argo CD.
  - Migrated without touching a workload: arda's Argo CD frozen first (both controllers to 0, every Application's and the ApplicationSet's finalizer removed), then ainur's took over the same app names, so the resources' tracking annotations already matched and nothing changed; then arda's Argo CD uninstalled (`install.yaml`, the `argocd` namespace). Checked: all 27 apps Synced, 25 Healthy, `gitlab-runner` Progressing (its pod had been crash-looping for 30 hours before, 247 restarts) and the root app with it; 115 pods running (the 122 before less Argo CD's 7), all 59 claims Bound, no pod restarted. ainur's application controller went from about 460 to 760 MiB; arda saves about 750 MiB.
  - **Watch**: `argocd-manager`'s token doesn't expire; it's in ainur's `cluster-arda` Secret only. arda's API address is its one control plane, `192.168.1.53`; with three, it wants a VIP. While ainur is down, nothing syncs to arda.
- Not listed, on purpose: `auth.kidd.network` (the login's callback) and the tunnel's route for ainur's sites (`cloudflared/ainur-homepage`); Plex's LAN port and Paperless's SMB share belong to apps already listed.

### Observability (promoted from Tier 4, 2026-11-18; built 2026-11-19)

- **Dashboards, organised** (2026-11-22): Grafana files each dashboard by its ConfigMap's `grafana_folder` annotation (sidecar `folderAnnotation`): **Lab** (the lab's own: Homepage's status and charts, later the rack screen), **Cluster** (the chart's 22: Kubernetes, nodes, Prometheus, Alertmanager), **Apps** (the workloads', none yet). The chart's AIX and macOS node dashboards are off. Everything is in Git; Grafana holds nothing.
- **Dashboards built** (2026-11-22). Every one is a ConfigMap in `src/manifests/ainur/monitoring/dashboards/`, filed by its `grafana_folder` annotation:
  - *Lab*: Lab status and Both clusters (Homepage's), and **Rack** (`rack-dashboard.yaml`), for a screen in the rack: the status tiles, CPU, memory and temperature per machine, network, the outside checks over time, the largest volumes, then the alerts firing and pods not running by name, sized for 1080p landscape. Shared without a login (tag `shared`); its link is on the admin Homepage under Lab ("Rack screen"). For the screen itself: any small device with a browser in kiosk mode at that link, on the LAN.
  - *Apps*: **Media** (series, movies, what's missing, subtitles, indexers, health issues, free space, qBittorrent speeds and torrents), **Games** (players online and response per Minecraft server), **Notes and alerts** (Obsidian's CouchDB requests and writes, ntfy messages and subscribers).
  - *Cluster*: **Edge** (arda's Traefik per site, 4xx/5xx, the tunnel's requests and connections, the outside checks' timings), **Storage and backups** (Longhorn per node and per volume, VolSync per volume), and the chart's 22.
  - Checked: every panel of every one returns data through Grafana's query API.
- **App metrics** (2026-11-22), each found by a monitor, so a new app or server needs no list changed: Traefik (the chart's ServiceMonitor, per-router labels), cloudflared (it served metrics on :2000 already; a PodMonitor), GitLab runner (the chart's; not serving while the runner is off), CouchDB (its native `[prometheus]` port 17986, without the login, on a Service of its own that nothing routes the internet to), ntfy (a metrics listener of its own, :9090, not the public one), Sonarr/Radarr/Prowlarr/Bazarr (an exportarr sidecar each, with their existing API keys), qBittorrent (an exporter Deployment; the pod network needs no login), Minecraft (an mc-monitor sidecar on every server). The media and minecraft namespaces each have one PodMonitor for any pod with a port named `metrics`.
- **More metrics** (2026-11-22, later): visitors' **country** (Traefik's `headerLabels`: Cloudflare's `CF-IPCountry` on everything through the tunnel; LAN requests have none), **Argo CD** (user-data's chart makes metrics Services for the controller, server, repo server and ApplicationSet; applied live on valar-50 too), **cert-manager** (its Service already existed), both monitored from `monitoring/bootstrap-charts-metrics.yaml` (not the charts: at first boot the CRD doesn't exist), and **Home Assistant** (its Prometheus integration; setup.py keeps a long-lived token named `prometheus` in the `homeassistant-metrics` Secret, through a Role for that one Secret, made again if it stops working). Dashboards: Edge gained visitors by country (since 2026-11-23 unique visitors, from Traefik's access log in Loki, as map markers: a heatmap draws nothing for one country); **GitOps and certificates** (Cluster); **Home** (Apps). Alerts: `CertificateExpiringSoon` (under 14 days: renewal failed), `ArgoAppOutOfSync` (an hour), `ArgoAppUnhealthy` (30 minutes). Checked: every panel returns data (Home's temperatures wait for sensors).
- **Still to do for metrics**: Plex and Jellyfin streams wait on their setup (Plex unclaimed, Jellyfin's first-run wizard not done): then an exporter with Plex's token, and one with a Jellyfin API key. A CI dashboard once the GitLab runner is back. Players and streams on the rack screen.
- **A shared dashboard can't repeat panels by variable** (tested 2026-11-22 on Grafana 13: the variable is kept, but the no-login query endpoint returns nothing for it). So the **Machines** dashboard (Lab, shared, on the admin Homepage under Charts) is written by a job: `monitoring/grafana-nodes.yaml` reads the machines from `node_uname_info` every 5 minutes and writes a stat tile per machine, four to a row, each with CPU, memory, network (in plus out) and hottest temperature, coloured by thresholds. No list: a new machine gets its tile by itself. It rewrites only when its output changes (a hash in the description), and a Grafana restart is mended on the next run. Checked: 7 tiles, each with all four values, through the shared link. **Then combined** (2026-11-22): the job writes **Lab status** (uid `nodes`): the status tiles, read from the `homepagestatus` dashboard so they are defined once, then the machines; it is the only embed on the admin Homepage (Lab status), its height set in `homepage/logo.yaml`'s custom.css (`iframe[name="lab"]`, 44rem) since Homepage's height classes stop at 384px. Tiles use Homepage's palette (Tokyo Night moon, whose #222436 is its background: green #c3e88d, orange #ff966c, red #ff757f, blue #82aaff) on transparent panels; the machine tiles' graphs each have their own range (`fieldMinMax`: shared, the network's bytes flattened the rest). Grafana's own page colour can't follow: open-source Grafana takes no custom theme. "Both clusters, last 6 hours" is no longer embedded (still in Grafana). **Then a table** (later the same day): Grafana only draws a stat row's graph when the row is over ~50px, so per-machine tiles with four rows lost their graphs at Homepage's 390px. Lab status is now `dashboards/lab-dashboard.yaml` (uid `lab`, a file in Git): a table with a row per machine (Time series to table, merged on the machine), CPU, memory, network and temperature each a sparkline cell with its value, dark with only the graphs in colour (#82aaff, amber #ffc777 when risky, red #ff757f when wrong), and the alerts firing beside it with the last day's graph. A row opens Node Exporter / Nodes set to that machine; the alerts open Grafana's firing list. One query lists the machines, so the `grafana-nodes` generator is gone. Later: the alerts row moved above the machines, the same width (960px). **Styling inside the embed, not built**: Homepage's CSS can't reach into the frame (another origin). The route if wanted: an init container running the same-version (non-distroless) Grafana image that copies `public/views/index.html`, adds a `<style>` from a ConfigMap (scoped to shared-dashboard pages: background as Homepage's card, its hover, optionally no title row or "Powered by"), and hands it to Grafana; re-patched every start, so upgrades bring their own template, and it falls back to the unpatched one if the patch no longer matches. Ruled out: experimental themes (`grafanaconThemes`: none is #222436, not customisable), panel styles (presets, no custom colours), a `<style>` in a text panel (needs HTML sanitising off).

- **On the admin Homepage** (2026-11-22): the dashboarding is all Grafana's; Homepage is the front door and only shows it. Two dashboards tagged `shared`, shared without a login and embedded above the services: **Lab status** (`monitoring/dashboards/homepage-status-dashboard.yaml`), stat tiles coloured by thresholds (alerts firing, nodes not ready, outside checks failing, backups missed, Omni's last backup, Longhorn used and full, pod restarts in the last hour), and **Both clusters, last 6 hours** (`monitoring/dashboards/homepage-dashboard.yaml`): CPU, memory, network, hottest zone per machine. Homepage's native Prometheus cards and its node bar were tried and dropped: they duplicated Grafana in a second config. A shared dashboard is read-only and runs only its own saved queries; the rest of Grafana still needs Dex. Grafana keeps nothing on disk, so the `grafana-share` CronJob (`monitoring/grafana-share.yaml`) checks every 2 minutes that each dashboard tagged `shared` is shared, remaking it under its own fixed link token, made once at random into the `grafana-share` Secret keyed by uid; Homepage reads them as `HOMEPAGE_VAR_GRAFANA_SHARE_<uid>` (envFrom with a prefix; Reloader restarts it when one is added). Tag a new dashboard `shared`, add an iframe card for it, and it's shared. The job logs in to Grafana's API with an admin login it makes once into the `grafana-admin` Secret (basic auth on for the API; the login form stays off). **Fixed on the way:** left to the chart, Grafana's admin password was random on every render (Argo CD can't look up the last one), so `checksum/secret` changed and Grafana redeployed on every push to main, losing its database (sessions and the shares). Now `grafana.admin.existingSecret: grafana-admin`; two forced re-renders left it untouched. Checked: both shares load with no login and no `X-Frame-Options`, every panel returns data, Homepage's tokens match the Secret, the regular API without a login is 401. Grafana is LAN-only, so the figures show only at home.

2026-11-18 showed what its absence cost: valar-51/52 hung with no record of why, the NVMe dropouts were found from console screenshots, Longhorn volumes faulted silently, and on 2026-11-19 valar-50's SD card was found by hand to be taking 8.6 MB/s of writes from our own CronJobs.

Built, on ainur (`src/manifests/ainur/monitoring*`), pinned to valar-50 with its data on the NVMe (`local-path-kept`):

- **Metrics**: kube-prometheus-stack 93.4.1. Prometheus (15 days, 8 GB) scrapes ainur and receives arda's by remote write; arda runs the same chart in agent mode (`src/manifests/arda/monitoring`), so the standard dashboards and rules cover both, told apart by `cluster`. k3s's and Talos's built-in control-plane scrapes are off (nothing separate to scrape). VolSync's metrics are scraped without its auth proxy (`metrics.disableAuth`), and Longhorn's too.
- **Logs**: Loki 3.6, single binary, 14 days. Both clusters' pod logs and events through k8s-monitoring's Alloy.
- **Grafana** at grafana.kidd.network behind Dex (a public PKCE client, no password login), on the admin Homepage. Stateless: dashboards are config.
- **Alerts** (`monitoring/lab-rules.yaml`), beside the chart's standard ones: disk I/O stalls, Omni's backup or a VolSync backup missed, a faulted Longhorn volume, arda going silent.
- **To your phone** through ntfy (`monitoring/ntfy.yaml`) on ainur, at ntfy.kidd.network on the LAN and through arda's tunnel: warnings and critical alerts, resolved ones too, to the `lab-alerts` topic. Log in as `admin` with the admin password (`set-admin-password.sh`). Tested end to end (2026-11-19).
- arda pushes to `prometheus.kidd.network/api/v1/write` and `loki.kidd.network/loki/api/v1/push` (only those paths), trusting the lab CA from the `ainur-telemetry` Secret arda-bootstrap writes.

Not yet:

- **A dead man's switch** (built 2026-11-21): Alertmanager sends its always-firing `Watchdog` every 10 minutes to the public ntfy.sh (no account), as an alert scheduled 30 minutes ahead under a fixed sequence ID, so each heartbeat replaces the last. If ainur, its monitoring or its internet dies, the last one is delivered. Tested on ntfy.sh before building: a second publish replaced the pending first, and only one was delivered. The URL (`AINUR_DEADMAN_URL` in `.env`, its topic the password) reaches Alertmanager as a mounted Secret file (`url_file`). 144 messages a day of ntfy.sh's 250. Needs the phone subscribed to that topic on ntfy.sh, as well as to `lab-alerts` on ntfy.kidd.network.
- **UniFi's logs** (firewall, system) over syslog into Loki, and GeoIP for who hits the forwarded ports.
- **Checks from outside** (built 2026-11-21, `src/manifests/arda/monitoring/blackbox`): a blackbox exporter on arda resolving through 1.1.1.1, so each tunnel site is fetched from Cloudflare's side and each forwarded TCP port reached at the public address through the router (it hairpins). Targets come from the publishing annotations (`kidd.network/tunnel` on Ingresses, `kidd.network/port-forward` on Services), so a new site or server is checked with nothing added: 6 sites and creative's 2 TCP ports at first, all passing; a site with no tunnel route and an unforwarded port both fail. `ExternalCheckFailing` (warning, to ntfy) after 10 minutes, or if the checks stop running. **Not covered**: UDP (Dragonwilds, Bedrock's 19132/19133; a blackbox probe can't tell a UDP port works), and the line itself from outside, since the probes start inside.
- The ingest endpoints are unauthenticated, like the rest of the LAN (see VLANs).
- No Tempo (traces) or Mimir: nothing emits traces, and Prometheus is plenty at this size.

---

## Tier 2 — Defensive depth (when bored, or after Tier 1)

### VLANs

- Everything shares one LAN. Minecraft and Dragonwilds take port forwards from the internet, so a hole in a server or plugin puts someone next to the Pis' SSH and every admin UI.
- **Plan**: Infrastructure (UniFi, JetKVMs, PDU/UPS), Lab (ainur, arda, the bootstrap VM), Exposed (game servers and anything else published: reaches nothing else), Work (the work laptop), Users, Guests, IoT (Home Assistant's devices).
- **Watch**: netboot (option 66, TFTP, NFS, proxy DHCP) and kube-vip's ARP on `.59` all assume one segment; the Pis and the VM have to stay together, and DHCP relay or per-VLAN options decide what crosses. Plan it before moving anything.
- Remote access is UniFi Teleport (or its plain WireGuard server); clients need the gateway as DNS for `*.kidd.network`, and the lab CA installed.

### Secrets pushed, not served (done 2026-11-19)

Until 2026-11-19 every `AINUR_*` and `ARDA_*` value, the lab CA's private key included, was readable by anyone on the LAN: at `/secrets/*.env` from the VM and from ainur's VIP, the agent token at `/k3s/k3s-agent-token`, and the Pi password and both k3s tokens inside `user-data` and the SD card image.

Now nothing secret is served or in an image:

- An image holds only `AINUR_PUSH_PUBKEY`. There's no password: SSH takes that key and nothing else, and the console has no login.
- A booting Pi waits, saying so in `/run/ainur/awaiting-push`, until `push-secrets.sh` SSHes in with `AINUR_PUSH_KEY` and writes `/run/ainur/` (RAM). The bootstrap VM (compose `pi-secrets-pusher`) has all of `.env`: both k3s tokens for a waiting Pi, and `ainur.env`/`arda.env` for the k3s server, whenever they change. ainur's `secrets-pusher` Deployment has only the push key and the agent token, for a netbooted Pi's every boot.
- Pis are found by scanning the /24 for SSH servers that say Ubuntu and take the key; not a list.
- The lab CA's key reaches no Secret now (gen-lab-certs.sh makes it cert-manager's), and the push key only `ainur-netboot`'s.

Still open:

- **A pusher can't tell a Pi from an impostor.** A netbooted Pi makes new SSH host keys every boot, so there's nothing to pin. Something that answers SSH as Ubuntu, takes any key and claims to be waiting gets what that pusher has: the agent token from ainur's, and everything from the VM's. Far harder than one `curl`; VLANs (below) close it.
- **The NFS root was exported read-write to anyone** (read-only since 2026-11-21). A leftover from when the Pis shared `/home` over NFS (`/mnt/nfsshare/home`), where the old leader election kept the k3s leader and token (Guides: Netbooting Raspberry Pi, 7-overlay). The Pis mount only their root, read-only, and the builders write the share through their own volumes, so nothing needed `rw`. Still exported to the whole LAN, which can read the image: nothing secret is in it.

### External Secrets Operator (assessed 2026-11-22, not built)

Three gaps in how pushed secrets reach the apps:

- **arda's are a hand-kept list.** `arda-bootstrap-job.yaml` has a block per app mapping `ARDA_*` values to Secrets, so a new arda app means editing a Job on ainur.
- **Every ainur namespace gets every value.** `ainur-secrets.sh` copies all `AINUR_*` (less the push key and, since 2026-11-23, the k3s tokens) into a fixed list of namespaces: Homepage can read ntfy's hash, the ntfy token and the dead man's switch URL. Dex, the one on the internet, now loads only its two.
- **Changes reach arda late.** An edited `ARDA_*` arrives when `arda-bootstrap` next runs (up to an hour), and nothing restarts the app.

The fix: ESO on both clusters, Kubernetes provider, reading the Secrets the pusher already writes on ainur (arda through ainur's API, with a token that can read only `arda-secrets`). `.env` stays the root, nothing goes online, each app's `ExternalSecret` sits beside it naming only its keys, and Reloader (as on ainur) restarts on change. `arda-bootstrap` shrinks to handing arda that one token.

Not Vaultwarden as ESO's backend: it would live on arda, so a rebuild can't restore it before the secrets its restore needs (circular), and ESO's Bitwarden provider needs Bitwarden Secrets Manager, which Vaultwarden doesn't implement (only a `bw serve` webhook workaround). Vaultwarden is for people's passwords (More workloads, above), and being in the lab it can't be the only copy of `ARDA_VOLSYNC_PASSWORD`.

### Secure Boot on arda

- arda's machines run with Secure Boot off: ainur's `ipxe.efi` isn't signed with a key the firmware trusts, and the installs come from non-Secure Boot images.
- **Fix**: Talos's Secure Boot images from the factory (a `secureboot` schematic), Sidero's keys enrolled in each machine's firmware, and a signed loader in front of iPXE for network boot. Then flip the firmware to Secure Boot on.

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

### Argo CD Ingress uses cert-manager (done 2026-11-22)

- A lab-CA certificate (`argocd-tls`) and a `tls:` block, like Dex's, instead of Traefik's default certificate. The missing `tls:` was also why Homepage linked Argo CD as `http://`: it picks the scheme from `spec.tls`. Applied live on valar-50 (`/etc/k3s-manifests` and k3s's manifests directory) as well as in user-data.

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

### Offline knowledge

What makes an offline lab worth having rather than merely resilient.

- **Kiwix** (`kiwix-serve`): ZIM snapshots of Wikipedia (~110 GB with images, ~50 GB without, ~10 GB top articles), Wikivoyage, WikiMed, Stack Exchange, iFixit, Project Gutenberg (~70 GB), Khan Academy. One small container serves them all; a CronJob refreshes them from `download.kiwix.org` while online, and offline the last copy stays.
- **Books**: Gutenberg's ZIM for public domain; Kavita or Calibre-Web for an own ebook library.
- **A general-knowledge LLM**: Ollama (shared with Home Assistant) behind Open WebUI, Dex in front. Open WebUI searching Kiwix keeps a small CPU model answering from local sources, and gives Jarvis answers with the internet down.
- **Maps**: OpenStreetMap tiles for the region, served locally.
- **Storage**: large and rarely changing, so the NAS, not Longhorn (three replicas of 110 GB doesn't fit a 1 TB SSD). Until then, the no-pictures and top-articles ZIMs.

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

*Last reviewed: 2026-11-23, after the users and admins tiers, the friends' tunnel and the security sweep; stale entries brought up to date.*
