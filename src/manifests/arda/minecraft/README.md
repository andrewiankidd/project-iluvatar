# Minecraft on arda

Each folder under `servers/` is one Paper server that Java and Bedrock players
both join (Bedrock through Geyser and Floodgate). The folder name is the
server's name, and everything else is derived from it:

| Name | What |
|---|---|
| `<name>.minecraft.kidd.network` | the game: Java on TCP 25565, Bedrock on UDP 19132 |
| `minecraft.kidd.network/map/<name>/` | the BlueMap 3D web map |
| `minecraft.kidd.network` | the portal: every server, live status, map links |

The portal and maps come in through the Cloudflare Tunnel (`../cloudflared.yml`),
with Cloudflare's HTTPS. The game cannot: `<name>.minecraft.kidd.network` is a
DNS-only CNAME to `home.kidd.network` (`../ddns.yml`), and the router forwards
TCP 25565, UDP 19132, TCP 19132 and UDP 19133 to the server's LoadBalancer
address. Maps are paths rather than hosts because Cloudflare's free
certificate covers one level below `kidd.network` only.

## Pieces

- `../minecraft.yml`: the `minecraft-servers` ApplicationSet (one app per
  `servers/*/server.yaml`) and the `minecraft-shared` app (this folder's
  `kustomization.yaml`: the portal plus `common/patches`).
- `common/values.yaml`: chart values every server shares: image, Paper build,
  plugins, persistence.
- `common/patches/`: plugin config patches applied at each start. Geyser's sets
  `transport: both`, NetherNet's WebRTC port (UDP 19133) and the address it
  advertises (`CFG_BEDROCK_ADDRESS`, set per server by the ApplicationSet).
- `servers/<name>/server.yaml`: title, description and portal order.
- `servers/<name>/values.yaml`: what differs for that server (mode, difficulty,
  motd), and its NPCs under `npcs:`.
- `common/files/npcs.dsc`: the Denizen script that makes a server's NPCs match
  its `npcs:` list: it creates and removes them, and moves each through its
  daily schedule (shop, stand, sit, sleep, wander). Trading is open only at a
  shop, in its hours. The list's format is described in
  `servers/creative/values.yaml`; `/npcspot <name>` in game records a place.
- `common/files/protection.dsc`: sets WorldGuard's `__global__` region in each
  world from a server's `protection:` list on every start: who may build, and
  what everyone else may do. Creative is open to anyone this way, read-only
  apart from switches and doors; survival is whitelisted.
- `portal/`: nginx serving `index.html` and each server's map at
  `/map/<name>/` (`nginx.conf.template`), plus a refresher that lists the
  Services labelled `minecraft.kidd.network/server` and pings each over the Java
  and Bedrock protocols every 30 seconds. It holds no server list of its own.
- `../external-dns.yml`: publishes the servers' records;
  `../external-dns-tunnel.yml` points the portal's at the tunnel.

## Adding a server

Create `servers/<name>/server.yaml` and `servers/<name>/values.yaml`, then push.
The ApplicationSet creates the app, external-dns creates the records, and the
portal lists it on its next refresh.

On its first start, a new server writes Geyser's default config after the
patches have already run, so Bedrock (NetherNet) uses the patched settings only
from the second start onward. Restart it once:
`kubectl -n minecraft rollout restart deploy/<name>-minecraft`.

Removing a folder removes the app but keeps its PersistentVolumeClaim
(`preserveResourcesOnDeletion`, `Prune=false,Delete=false`).

## What arda provides

All in this repo now:

- MetalLB (`../metallb.yml`): one LAN address, 192.168.1.58, which every
  LoadBalancer Service shares (`metallb.io/allow-shared-ip: arda`), each on
  its own ports. Each server's Service mixes TCP and UDP ports on it.
- Traefik (`../traefik.yml`) as the `traefik` IngressClass, as
  `traefik.kube-system`, where cloudflared sends the tunnel's traffic.
- Longhorn (`../longhorn.yml`) as the default StorageClass.
- The `cloudflare-api-token` Secret in both `external-dns` and `ddns`, and the
  `cloudflared-tunnel` Secret in `cloudflared`, from arda-bootstrap; see
  `../external-dns.yml`, `../ddns.yml` and `../cloudflared.yml`.
- The router's port forwards above, kept in UniFi by ainur's
  `unifi` CronJob from the Service's
  `kidd.network/port-forward: "true"`.

## Restoring a world from a backup

Done for creative on 2026-11-21, from arda-local's last backup
(`creative-<time>.tar.gz`, made by its `backup.sh`: `/data` without the jars,
libraries and BlueMap's render).

1. Pause the server's app, then stop the server. `minecraft.yml` lets the
   automated sync be removed by hand without the ApplicationSet restoring it.
   On ainur, whose Argo CD deploys arda's apps:
   `kubectl -n argocd patch app minecraft-<name> --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`,
   `rcon-cli save-all flush`, then
   `kubectl -n minecraft scale deploy/<name>-minecraft --replicas=0`.
2. A throwaway pod (alpine, as root) mounting `<name>-minecraft-datadir`.
3. Get the archive *into the pod over the LAN*, not through `kubectl exec`'s
   stdin or `kubectl cp`: those go through Omni's API proxy, which dropped a
   212 MB upload partway. Serve it for a minute from any LAN host
   (`python3 -m http.server`) and `wget` it in the pod; check its sha256.
4. In the pod: delete everything in `/data` except what the server downloads
   (`libraries`, `versions`, `cache`, `.cache`, `*.jar`, `plugins/*.jar`),
   untar the archive into `/data`, then `chown -R 1000:2000 /data` and
   `chmod -R g+rwX /data` (the chart runs as uid 1000 with fsGroup 2000).
5. Delete the pod, and put the automated sync back:
   `kubectl -n argocd patch app minecraft-<name> --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'`.
   Argo CD scales the server back up; its log shows `Preparing level "world"`
   and `Done`. BlueMap redraws its map over the next while.

VolSync backs the world up to R2 the following night (see the backups in
`../kyverno-policies/volsync.yaml`).

Who may join (survival) and who may build (creative) are UUIDs in the
`minecraft-players` Secret (see `minecraft.yml`), not in this repo. A Bedrock
player's is Floodgate's, from the "not whitelisted" log line or
`fwhitelist add <gamertag>`.
