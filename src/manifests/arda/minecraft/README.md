# Minecraft on arda

Each folder under `servers/` is one Paper server that Java and Bedrock players
both join (Bedrock through Geyser and Floodgate). The folder name is the
server's name, and everything else is derived from it:

| Name | What |
|---|---|
| `<name>.minecraft.kidd.network` | the game: Java on TCP 25565, Bedrock on UDP 19132 |
| `map.<name>.minecraft.kidd.network` | the squaremap web map |
| `minecraft.kidd.network`, `*.minecraft.kidd.network` | the portal: every server, live status, map links |

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
- `portal/`: nginx serving `index.html`, plus a refresher that lists the
  Services labelled `minecraft.kidd.network/server` and pings each over the Java
  and Bedrock protocols every 30 seconds. It holds no server list of its own.
- `../external-dns.yml`: publishes all of the names above to Cloudflare.

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
- Traefik as the `traefik` IngressClass.
- cert-manager, for the `letsencrypt` ClusterIssuer in `../cert-issuers.yml`.
- A default StorageClass, or set `persistence.storageClass` in `common/values.yaml`.
- The `cloudflare-api-token` Secret in both `external-dns` and `cert-manager`;
  see `../external-dns.yml` and `../cert-issuers/letsencrypt.yaml`.

## Moving the creative world in

1. Push, then scale it to zero once its app syncs:
   `kubectl -n minecraft scale deploy/creative-minecraft --replicas=0`.
2. Mount the claim `creative-minecraft-datadir` in a throwaway pod and untar a
   `/data` backup into it. Leave out `plugins/*.jar`; the server downloads them.
3. `chown -R 1000:1000` the data, delete the pod, and scale back to 1.
4. Delete the hand-made `creative.minecraft.kidd.network` record in Cloudflare.
   external-dns does not overwrite records it does not own.

Bedrock players are whitelisted through Floodgate: `fwhitelist add <gamertag>`.
