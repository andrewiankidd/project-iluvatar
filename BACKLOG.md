# project-iluvatar — Backlog

Honest internal tracking of gaps, debt, and "would be nice" items that don't belong in the user-facing docs. Reviewed conversationally on 2026-11-17.

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

- **The netboot volumes on a rebuild** still use plain local-path, so a rebuilt ainur makes new folders and leaves the old `pvc-*` ones on valar-50's NVMe. They rebuild from Git, so nothing is lost, but the old folders want clearing.
- **An offline restore.** `omni-restore` fails rather than start Omni empty if R2 can't be reached, so a new NVMe with no internet leaves Omni waiting. A LAN S3 target would cover it.
- **The lab CA survives a rebuild now** (2026-11-18): `AINUR_LAB_CA_CRT`/`AINUR_LAB_CA_KEY` in `.env`, used by `gen-lab-certs.sh`. Until then every rebuild made a new CA on valar-50's SD card, and every arda machine (and device) stopped trusting Omni.
- **valar-51/52's NVMe** sit unused, and valar-50's still holds Longhorn's old replicas under `/var/mnt/nvme`.
- Rebuilding the control plane still takes the VIP down while it netboots, so that re-flash needs the bootstrap VM serving netboot (`rebootstrap.sh` now points DHCP option 66 at it and ainur's `unifi` CronJob points it back).

Considered and set aside:

- **etcd snapshots in S3**, restored by a fresh cluster before k3s starts (`--etcd-s3`, `--cluster-reset-restore-path`), so Longhorn's records point at the replicas still on the NVMe. The original design here. Needs a fixed server token, snapshots fresh enough, a LAN S3 target offline, and etcd, which the SD card couldn't carry. Restoring the volumes themselves turned out simpler.
- **Keeping etcd on the NVMe**, with all three Pis as control planes. Works, and keeps the VIP up through any one reboot, but the nodes stop being stateless and the bootstrap scripts change throughout.
- **Static local volumes at fixed paths.** Survive a rebuild with no snapshot, but give up Longhorn's replication.
- **Back up, rebuild, restore the volumes** (Longhorn system backup). Throws away the replicas on every rebuild.
- **Ceph through Rook**, which can adopt its own disks. Far too heavy for Pis.

---

## Tier 1 — arda's foundations (built 2026-11-17, not yet run)

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

- Longhorn's own nightly backups (`longhorn/recurring-jobs.yaml`, two weeks kept) to **Cloudflare R2**, bucket `arda-backups`. No Velero: Argo CD rebuilds every Kubernetes object, so only volume data needs backing up.
- The bucket exists (2026-11-17, Western Europe), and `ARDA_BACKUP_*` are in `.env`: an R2 token's ID as the access key, the SHA-256 of its value as the secret. They passed an S3 write, list and delete. Rolling or deleting that token stops backups until the keys are derived again.
- **Then**: a DR drill. Nuke everything, rebuild from `start.sh` plus a restore, write down what broke.

### Off the stopgap

- `arda-local` runs Minecraft and Dragonwilds on a workstation until arda is up. It reads the same `ARDA_*` names from its own `.env`, so the lines are shared. Moving them means restoring each world into its Longhorn volume on arda, then retiring the stopgap. Never run both: they share the tunnel and the DNS records.

### CI runner (built 2026-11-19)

- `src/manifests/arda/gitlab-runner.yml`: the official chart, Kubernetes executor, `concurrent: 2`, registered with the Multipass VM runner's own `glrt-` token (`ARDA_GITLAB_RUNNER_TOKEN`). One runner in GitLab, two managers, so retiring the VM is switching it off; its repo needs nothing else.
- **Retire the VM** once a real pipeline has run on arda: until then, jobs go to whichever manager asks first.
- **Trade-off**: privileged `docker:dind` job pods, kept because every pipeline already uses it. A job is root on valinor-53, next to the games, and runs whatever any project holding the token pushes. Rootless BuildKit (or `docker buildx` with a remote rootless buildkitd in the namespace) would end that, at the cost of rewriting each pipeline's build steps.
- **No build cache**: each job's image layers are an emptyDir, gone when it ends. The chart can use an S3 cache; an R2 bucket would do.
- Jobs reserve 1 GiB and may use 4 GiB on a 16 GB machine Minecraft mostly fills; two Cypress jobs at once can push the games' pods towards eviction. Watch it in Goldilocks.

### Obsidian (built 2026-11-19)

- `src/manifests/arda/obsidian.yml`: CouchDB 3.5 for the Self-hosted LiveSync plugin at `obsidian-sync.kidd.network` (public through the tunnel, and on the LAN), and linuxserver/obsidian in the browser at `obsidian.kidd.network` (tunnel and LAN, behind the Dex login; linuxserver's own login off). CouchDB's user `obsidian`, password `ARDA_OBSIDIAN_PASSWORD`. Checked: public HTTPS (Cloudflare's certificate), LAN HTTPS (lab CA), writes and reads, CORS for `app://obsidian.md`.
- **One Dex login for arda** (`src/manifests/arda/oauth2-proxy.yml`): forward-auth Middleware `oauth2-proxy-dex`, Dex client `arda`, callback `auth.kidd.network`, cookie `_kidd_auth` on `.kidd.network`. Dex is on the tunnel (by annotation, below). Checked as far as Dex's login page, from outside and at home, returning to `https://`; a real sign-in and Selkies' websocket through the proxy not yet tried.
- **ainur on the tunnel** (`ainur/sidero-omni/arda-tunnel-cronjob.yaml`): every ainur Ingress annotated `kidd.network/tunnel: "true"` is copied to arda's `cloudflared` namespace, forwarding to ainur's Traefik. Dex, Grafana, Headlamp and Argo CD are on it (Argo CD's Ingress lives in the Pis' `user-data`, annotated there and live). Checked from outside: each reaches Dex's login page. Omni stays LAN-only: its machine and Kubernetes endpoints are not browser logins.
- **Off for now** (2026-11-19): credentials were found in the public repo, so nothing behind Dex is on the internet: the annotations are gone from Dex, Grafana, Headlamp, Argo CD, Obsidian in the browser and `auth.kidd.network`, and the `arda-tunnel` CronJob is suspended. Still public: the public Homepage and `ntfy`, Minecraft, and the LiveSync CouchDB (its own password, only in `.env`). Turn back on after rotating, with Dex hardened.
- **Watch**: Dex is now on the internet with static passwords, no rate limit, no second factor. Cloudflare rate limiting on `dex.kidd.network/auth/*`, or an upstream identity provider with MFA as Dex's connector, would harden it.
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

### Paperless (built 2026-11-19)

- `src/manifests/arda/paperless.yml`, namespace `paperless`: Paperless-ngx 3.5.1 at `paperless.kidd.network` (tunnel and LAN, private Homepage), one pod with a Valkey 9.0 broker and a Samba sidecar (`servercontainers/samba`, smbd only). SQLite in `paperless-data` (5 Gi), documents in `paperless-media` (20 Gi), both backed up by VolSync (checked: their `-volsync` Secrets, ReplicationSources and first backup pods appeared); `paperless-consume` (2 Gi) opted out, since files only pass through it.
- **Memory**: before, arda was at 81% used (12.3 GiB) with 79% requested. Paperless requests 640 MiB and is limited to 1.5 GiB. One task worker with two OCR threads and one web worker; it sits at ~570 MiB idle and ~700 MiB just after OCR. Left out for memory: Postgres (SQLite does for one household), Tika and Gotenberg (only Office files and `.eml` bodies need them). Add them with the second ProDesk.
- **Logins**: Dex client `paperless` (confidential, `AINUR_OIDC_CLIENT_SECRET`, PKCE too), through django-allauth. `PAPERLESS_SOCIAL_AUTO_SIGNUP`. The `paperless-setup` CronJob (`setup.py`, every 10 min, Paperless's own image) makes any user with a Dex social account a superuser. Local superuser `paperless` / `ARDA_PAPERLESS_ADMIN_PASSWORD` (generated). Checked on the LAN: login page with the Dex button, then a 302 to Dex with PKCE and the right callback, then Dex's "Log in to Your Account". From the internet: Paperless's login page (Cloudflare's certificate, 200). The Dex button can't work from outside while Dex is off the tunnel (no public DNS for `dex.kidd.network`). Not tried: a real Dex sign-in, and the CronJob's promotion of a Dex user.
- **Lab CA vs Python 3.14**: Paperless's Python refuses the lab CA ("CA cert does not include key usage extension", `VERIFY_X509_STRICT`, default since 3.13). Worked around in `paperless/sitecustomize.py`, which drops only that flag and only for `*.kidd.network` hosts (an expired public cert is still refused: checked). **The real fix**: re-issue the lab CA with `keyUsage = critical, keyCertSign, cRLSign` in `gen-lab-certs.sh`, keeping the same key so nothing that trusts it breaks. Every Python 3.13+ client of a lab-CA site will hit this.
- **Ingestion, checked**: an image-only PDF through the API and another dropped on `\\192.168.1.58\scan` (user `scanner`, `ARDA_PAPERLESS_SCANNER_PASSWORD`, SMB3) were both OCR'd and found by `?query=`; the share empties itself; a wrong password gets `NT_STATUS_LOGON_FAILURE`. SMB is LAN only: the LoadBalancer has no `kidd.network/port-forward` and no external-dns hostname.
- **Mail: off**, waiting for a mailbox. Set `ARDA_PAPERLESS_MAIL_HOST`/`_USER`/`_PASSWORD` (optional `_PORT`, `_FOLDER`), rebuild the served secrets, and the CronJob creates account and rule `inbox`: attachments only, mark read, 30 days. Untested against a real mailbox; the model fields and enums it uses were checked in the running 3.5.1.
- **Scanner**: scan-to-email suits most home scanners better than SMB (universal, works away from home, and many cheap devices only speak SMB1, which Samba refuses). The share is ready for one that does SMB2/3.
- **Left to do, in the UIs**: Paperless Mobile / Swift Paperless on the phone (server `https://paperless.kidd.network`; user `paperless` or a Dex user's password or API token from *My Profile*); tags, correspondents and document types as paperwork arrives. The two test documents (`api-test`, `smb-test`) can be deleted.
- **Watch**: the data and media volumes are backed up separately, minutes apart. A restore can find a document row without its file or the reverse, and `document_sanity_checker` reports it. For a guaranteed-consistent copy, a nightly `document_exporter` into a backed-up volume would do; not added (memory and space).

### Media (built 2026-11-19)

- `src/manifests/arda/media.yml`, namespace `media`, all LAN only: Seerr 3.5 (`seerr`), Prowlarr 3.0, Sonarr 4.0, Radarr 7.0, Bazarr 1.6, qBittorrent 5.1 + gluetun 3.41, Jellyfin 10.11, Plex (each at `<name>.kidd.network`, on the private Homepage under Media). Seerr is the merged Overseerr + Jellyseerr (2026), serving Plex and Jellyfin both.
- Dex (`oauth2-proxy-dex`) in front of Prowlarr, Sonarr, Radarr, Bazarr and qBittorrent; the arrs' auth is `External`, Bazarr's none, qBittorrent's skipped for `10.244.0.0/16`. Seerr, Jellyfin and Plex: their own users. Checked: each Dex-guarded host 302s to Dex's login; Seerr's and Jellyfin's first-run wizards answer; LAN DNS and lab-CA HTTPS for all.
- **Storage**: PVC `media`, 200 GiB Longhorn, `kidd.network/backup: "false"` (checked: no VolSync objects for it), TRaSH layout `/data/torrents/{tv,movies}` + `/data/media/{tv,movies}`, mounted at `/data` everywhere. Longhorn had 957 GB free. Each `*-config` volume is backed up as usual. RWO works because arda has one node; with more, pin the media pods together or go RWX. **The NAS**: an NFS PersistentVolume pre-bound to `media` (claimRef), same paths; and drop the Longhorn one, whose three replicas would want 600 GB once three nodes exist.
- **Wiring** (`media/wiring.mjs`, CronJob every 15 min, idempotent): API keys derived by `arda-bootstrap` from `ARDA_MEDIA_API_SECRET` (generated, in `.env`). Done and checked: Prowlarr → Sonarr and Radarr (applications), root folders in Sonarr and Radarr, Bazarr → Sonarr and Radarr (its `config.yaml`, written by a yq init container; Bazarr reports both versions). Waiting: qBittorrent as Sonarr's and Radarr's download client (they refuse to save one they can't reach: added on the first run after qBittorrent is up), and Seerr → Sonarr/Radarr (after its wizard).
- **Left to do, in the UIs**: Jellyfin's wizard (admin user; libraries `/data/media/tv`, `/data/media/movies`); Seerr's wizard (sign in with Jellyfin); indexers in Prowlarr; Bazarr's languages profile and subtitle providers (it warns "Missing languages profile" until then).
- **qBittorrent is held** (CreateContainerConfigError, by design) until `ARDA_MULLVAD_PRIVATE_KEY` and `ARDA_MULLVAD_ADDRESSES` are in `.env` and the bootstrap VM's served secrets are rebuilt. Then verify: its exit IP is Mullvad's (`am.i.mullvad.net`), and with the tunnel down (`ip link del tun0` in gluetun) qBittorrent's container reaches nothing. Mullvad has no port forwarding: no incoming peers.
- **Plex is held at 0 replicas: memory.** After Paperless, arda's requests were at 84% of 15.2 GiB; the media apps added ~1.5 GiB of requests (usage 87% with everything up). Plex's 384 MiB more would leave nothing for a transcode. Turn it on (`replicas: 1`, Homepage annotation `"true"`) with the second ProDesk. Claiming: a token from plex.tv/claim lasts 4 minutes, too short for `.env` → VM → arda, so it goes straight into a `plex` Secret in `media` at the moment Plex starts (`plex.yaml`).
- **Quick Sync, proposed, not done**: arda's GPU has no driver (`/dev/dri/card0` is `simple-framebuffer`, no `renderD128`). Add `siderolabs/i915` to `EXTENSIONS` in `ainur/sidero-omni/talos-schematic-job.yaml`: a new schematic, then an in-place Talos upgrade of valinor-53 through Omni (one reboot, no reinstall). Then give Jellyfin and Plex `/dev/dri`: Intel's GPU device plugin (`gpu.intel.com/i915`) or the generic device plugin, as on ainur; nothing on arda does that yet.
- **Remote streaming**: LAN only. A port forward (`kidd.network/port-forward: "true"` on a LoadBalancer Service) for Plex's 32400 or Jellyfin would allow it; the tunnel can't carry video under Cloudflare's terms.
- **Stremio fallback**: a self-hosted addon for when the hosted Torrentio is down. Not `torrentio-scraper` (crawlers and a database); Jackettio or Comet, which query the same Prowlarr on demand, one small container. Without debrid, Stremio streams torrents from the home IP.

### Home Assistant and a local assistant (the end goal)

- Replace Google Nest and the Hue cloud with Home Assistant plus a local LLM voice assistant: Whisper (speech to text), Piper (text to speech), Ollama behind Home Assistant's Assist, and Home Assistant voice satellites where the Nest speakers are. All local, so it fits the offline rule.
- **Home Assistant is up** (2026-11-19, `src/manifests/arda/homeassistant.yml`): the container image 2026.11.2 at `homeassistant.kidd.network`, LAN only, its own login, `/config` on Longhorn (VolSync's first backup ran), `configuration.yaml` from Git. On the host network in a privileged namespace; from the pod, mDNS sees the Hue Bridge, seven Google Cast devices (the Nest speakers and Chromecasts) and eight Matter devices. Onboarding (the owner account) is waiting for the user.

Next, in order:

- **Onboard and add what discovery offers**: the Hue Bridge first (local API, works while the bridge stays), the Google Cast devices for media and TTS.
- **Matter needs a Matter Server**: Home Assistant only talks to Matter through `python-matter-server`, an add-on on HA OS; here, its own Deployment on the host network (it needs IPv6 link-local on the LAN), added as the Matter integration at `ws://<it>:5580/ws`.
- **Wyoming services for Assist**: `wyoming-whisper` and `wyoming-piper` as Deployments on arda (CPU), added as Wyoming integrations by their Service names; Ollama after, sized against arda's RAM (~80% used with Home Assistant's ~600 MB).
- **Away from home**: the companion app needs Home Assistant reachable. The tunnel (`kidd.network/tunnel: "true"` on its Ingress) is one line, but puts Home Assistant's login on the internet; ip_ban is on (10 failed logins). Off until wanted. Cloudflare Access in front would break the app, as Dex would.
- **SSO**: not Dex (no OIDC in Home Assistant, and the apps can't do a browser login). When LLDAP exists, Home Assistant's `command_line` auth provider can check passwords against it; until then, its own users.
- **Bluetooth** isn't available (no adapter passed in, and arda's ProDesk may have none); ESPHome Bluetooth proxies would cover it over the network.
- **The IoT VLAN**: once devices move off the Lab VLAN, mDNS and SSDP won't cross by themselves; the UniFi gateway's mDNS reflector, or Home Assistant given a leg on that VLAN.
- **Zigbee over the network, not USB**: a PoE Ethernet coordinator (SLZB-06-style) lets Home Assistant run on arda without being pinned to the node with the dongle. Hue bulbs are Zigbee and pair to it directly, so the bridge and its cloud go.
- **The LLM starts on CPU.** GPUs are out of budget. Home Assistant's own intent matching handles plain commands instantly with no LLM; a small quantized model (3B-8B, Ollama) on a ProDesk handles the rest in seconds. A GPU box later changes nothing else. Supersedes LlamaGPT.
- On the Lab VLAN, its IoT devices on IoT. Whatever the household uses has to keep working mid-rebuild, so keep a manual fallback (switches, the Hue app) until it has earned trust.
- If the Nest setup includes cameras or a doorbell: UniFi Protect records locally and Home Assistant integrates with it.

### Observability (promoted from Tier 4, 2026-11-18; built 2026-11-19)

2026-11-18 showed what its absence cost: valar-51/52 hung with no record of why, the NVMe dropouts were found from console screenshots, Longhorn volumes faulted silently, and on 2026-11-19 valar-50's SD card was found by hand to be taking 8.6 MB/s of writes from our own CronJobs.

Built, on ainur (`src/manifests/ainur/monitoring*`), pinned to valar-50 with its data on the NVMe (`local-path-kept`):

- **Metrics**: kube-prometheus-stack 93.4.1. Prometheus (15 days, 8 GB) scrapes ainur and receives arda's by remote write; arda runs the same chart in agent mode (`src/manifests/arda/monitoring`), so the standard dashboards and rules cover both, told apart by `cluster`. k3s's and Talos's built-in control-plane scrapes are off (nothing separate to scrape). VolSync's metrics are scraped without its auth proxy (`metrics.disableAuth`), and Longhorn's too.
- **Logs**: Loki 3.6, single binary, 14 days. Both clusters' pod logs and events through k8s-monitoring's Alloy.
- **Grafana** at grafana.kidd.network behind Dex (a public PKCE client, no password login), on the private Homepage. Stateless: dashboards are config.
- **Alerts** (`monitoring/lab-rules.yaml`), beside the chart's standard ones: disk I/O stalls, Omni's backup or a VolSync backup missed, a faulted Longhorn volume, arda going silent.
- **To your phone** through ntfy (`monitoring/ntfy.yaml`) on ainur, at ntfy.kidd.network on the LAN and through arda's tunnel: warnings and critical alerts, resolved ones too, to the `lab-alerts` topic. Log in as `admin` with the Dex password. Tested end to end (2026-11-19).
- arda pushes to `prometheus.kidd.network/api/v1/write` and `loki.kidd.network/loki/api/v1/push` (only those paths), trusting the lab CA from the `ainur-telemetry` Secret arda-bootstrap writes.

Not yet:

- **A dead man's switch.** If ainur itself dies, nothing alerts. Alertmanager's `Watchdog` (always firing) to an outside check (healthchecks.io, or a second ntfy) would say so; online, but only for the alarm.
- **UniFi's logs** (firewall, system) over syslog into Loki, and GeoIP for who hits the forwarded ports.
- **Blackbox checks** from outside: does minecraft.kidd.network answer, does the tunnel.
- The ingest endpoints are unauthenticated, like the rest of the LAN (see VLANs).
- No Tempo (traces) or Mimir: nothing emits traces, and Prometheus is plenty at this size.

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

### Secrets pushed, not served (done 2026-11-19)

Until 2026-11-19 every `AINUR_*` and `ARDA_*` value, the lab CA's private key included, was readable by anyone on the LAN: at `/secrets/*.env` from the VM and from ainur's VIP, the agent token at `/k3s/k3s-agent-token`, and the Pi password and both k3s tokens inside `user-data` and the SD card image.

Now nothing secret is served or in an image:

- An image holds only `AINUR_PUSH_PUBKEY`. There's no password: SSH takes that key and nothing else, and the console has no login.
- A booting Pi waits, saying so in `/run/ainur/awaiting-push`, until `push-secrets.sh` SSHes in with `AINUR_PUSH_KEY` and writes `/run/ainur/` (RAM). The bootstrap VM (compose `pi-secrets-pusher`) has all of `.env`: both k3s tokens for a waiting Pi, and `ainur.env`/`arda.env` for the k3s server, whenever they change. ainur's `secrets-pusher` Deployment has only the push key and the agent token, for a netbooted Pi's every boot.
- Pis are found by scanning the /24 for SSH servers that say Ubuntu and take the key; not a list.
- The lab CA's key reaches no Secret now (gen-lab-certs.sh makes it cert-manager's), and the push key only `ainur-netboot`'s.

Still open:

- **Rotate.** Everything in `.env` was readable on the LAN for weeks: the k3s tokens, the lab CA, Cloudflare, R2, UniFi, Dex. Planned for the pre-live rebootstrap. A new lab CA means every device and arda machine trusting it again.
- **A pusher can't tell a Pi from an impostor.** A netbooted Pi makes new SSH host keys every boot, so there's nothing to pin. Something that answers SSH as Ubuntu, takes any key and claims to be waiting gets what that pusher has: the agent token from ainur's, and everything from the VM's. Far harder than one `curl`; VLANs (below) close it.
- **The NFS root is exported read-write to anyone** (`/mnt/nfsshare *(rw,...,no_root_squash)`, VM and ainur). Nothing secret is in it now, but anyone on the LAN could change what the netbooted Pis run. Export it read-only, to the Pis' addresses.

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

*Last reviewed: 2026-11-18, after the first end-to-end run of the x86 path and a pass through saved r/homelab posts.*
