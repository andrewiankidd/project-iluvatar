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
- `servers/<name>/values.yaml`: what differs for that server (mode, difficulty, motd).
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

## What arda has to provide

Not defined in this repo for arda yet:

- MetalLB, with a pool for the game LoadBalancer IPs. Each Service mixes TCP
  and UDP ports on one IP.
- Traefik as the `traefik` IngressClass, as `traefik.kube-system`, where
  cloudflared sends the tunnel's traffic.
- A default StorageClass, or set `persistence.storageClass` in `common/values.yaml`.
- The `cloudflare-api-token` Secret in both `external-dns` and `ddns`, and the
  `cloudflared-tunnel` Secret in `cloudflared`; see `../external-dns.yml`,
  `../ddns.yml` and `../cloudflared.yml`.
- The router's port forwards above, to the LoadBalancer address.

## Moving the creative world in

1. Push, then scale it to zero once its app syncs:
   `kubectl -n minecraft scale deploy/creative-minecraft --replicas=0`.
2. Mount the claim `creative-minecraft-datadir` in a throwaway pod and untar a
   `/data` backup into it. Leave out `plugins/*.jar`; the server downloads them.
3. `chown -R 1000:1000` the data, delete the pod, and scale back to 1.
4. Delete the hand-made `creative.minecraft.kidd.network` record in Cloudflare.
   external-dns does not overwrite records it does not own.

Bedrock players are whitelisted through Floodgate: `fwhitelist add <gamertag>`.
