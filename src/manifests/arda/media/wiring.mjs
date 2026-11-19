// How the media apps find each other, through their APIs (wiring.yaml).
// Adds what's missing and leaves what's there alone, so it can run again and
// again, and the UI's own changes stay. Never adds indexers or download sources.
//
//   Sonarr, Radarr   root folder under /data/media, qBittorrent as download client
//   Prowlarr         Sonarr and Radarr as applications (it pushes indexers to them)
//   Seerr            Sonarr and Radarr, once its first-run wizard is done
//
// Bazarr's side is in bazarr.yaml (its config file); Seerr to Jellyfin or
// Plex is Seerr's wizard (only the UI can sign in).
//
// An app that isn't up yet is skipped (the next run gets it); an app that
// answers with an error fails the run.

const ns = 'media.svc';
const key = (app) => process.env[`${app.toUpperCase()}_KEY`];
const apps = {
  sonarr: { url: `http://sonarr.${ns}:8989`, api: 'v3', root: '/data/media/tv', category: 'tv' },
  radarr: { url: `http://radarr.${ns}:7878`, api: 'v3', root: '/data/media/movies', category: 'movies' },
  prowlarr: { url: `http://prowlarr.${ns}:9696`, api: 'v1' },
  seerr: { url: `http://seerr.${ns}:5055`, api: 'v1' },
};

class NotUp extends Error {}

async function call(app, method, path, body) {
  const { url, api } = apps[app];
  let res;
  try {
    res = await fetch(`${url}/api/${api}${path}`, {
      method,
      headers: { 'X-Api-Key': key(app), 'Content-Type': 'application/json' },
      body: body && JSON.stringify(body),
      signal: AbortSignal.timeout(20000),
    });
  } catch (e) {
    throw new NotUp(`${app} not reachable (${e.cause?.code ?? e.message})`);
  }
  if (res.status === 502 || res.status === 503) throw new NotUp(`${app} starting (${res.status})`);
  const text = await res.text();
  if (!res.ok) throw new Error(`${app} ${method} ${path}: ${res.status} ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : null;
}

// A new item from the app's own schema, its fields set by name.
function fromSchema(schema, implementation, name, fields, extra = {}) {
  const item = structuredClone(schema.find((s) => s.implementation === implementation));
  if (!item) throw new Error(`no ${implementation} in schema`);
  for (const f of item.fields) if (f.name in fields) f.value = fields[f.name];
  return { ...item, name, enable: true, ...extra };
}

async function arr(app) {
  const { root, category } = apps[app];
  const folders = await call(app, 'GET', '/rootfolder');
  if (!folders.some((f) => f.path.replace(/\/$/, '') === root)) {
    await call(app, 'POST', '/rootfolder', { path: root });
    console.log(`${app}: root folder ${root} added`);
  }
  const clients = await call(app, 'GET', '/downloadclient');
  if (!clients.some((c) => c.implementation === 'QBittorrent')) {
    const schema = await call(app, 'GET', '/downloadclient/schema');
    const client = fromSchema(schema, 'QBittorrent', 'qBittorrent', {
      host: `qbittorrent.${ns}`,
      port: 8080,
      [app === 'sonarr' ? 'tvCategory' : 'movieCategory']: category,
    }, { protocol: 'torrent', priority: 1 });
    // forceSave: qBittorrent may be down (no Mullvad keys yet); save anyway.
    await call(app, 'POST', '/downloadclient?forceSave=true', client);
    console.log(`${app}: qBittorrent added`);
  }
}

async function prowlarr() {
  const existing = await call('prowlarr', 'GET', '/applications');
  const schema = await call('prowlarr', 'GET', '/applications/schema');
  for (const [app, implementation] of [['sonarr', 'Sonarr'], ['radarr', 'Radarr']]) {
    if (existing.some((a) => a.implementation === implementation)) continue;
    const item = fromSchema(schema, implementation, implementation, {
      prowlarrUrl: apps.prowlarr.url,
      baseUrl: apps[app].url,
      apiKey: key(app),
    }, { syncLevel: 'fullSync' });
    await call('prowlarr', 'POST', '/applications?forceSave=true', item);
    console.log(`prowlarr: ${implementation} added`);
  }
}

async function seerr() {
  const status = await call('seerr', 'GET', '/settings/public');
  if (!status.initialized) {
    console.log("seerr: first-run wizard not done yet; Sonarr and Radarr wait for it");
    return;
  }
  for (const app of ['sonarr', 'radarr']) {
    if ((await call('seerr', 'GET', `/settings/${app}`)).length) continue;
    const [profile] = await call(app, 'GET', '/qualityprofile');
    const { hostname, port } = new URL(apps[app].url);
    const server = {
      name: app === 'sonarr' ? 'Sonarr' : 'Radarr',
      hostname,
      port: Number(port),
      apiKey: key(app),
      useSsl: false,
      baseUrl: '',
      activeProfileId: profile.id,
      activeProfileName: profile.name,
      activeDirectory: apps[app].root,
      is4k: false,
      isDefault: true,
      externalUrl: `https://${app}.kidd.network`,
      syncEnabled: true,
      preventSearch: false,
      tags: [],
      ...(app === 'sonarr'
        ? { seriesType: 'standard', animeSeriesType: 'anime', enableSeasonFolders: true, animeTags: [] }
        : { minimumAvailability: 'released' }),
    };
    await call('seerr', 'POST', `/settings/${app}`, server);
    console.log(`seerr: ${server.name} added (profile "${profile.name}")`);
  }
}

let failed = false;
for (const [name, step] of [['sonarr', () => arr('sonarr')], ['radarr', () => arr('radarr')], ['prowlarr', prowlarr], ['seerr', seerr]]) {
  try {
    await step();
  } catch (e) {
    if (e instanceof NotUp) {
      console.log(`${name}: skipped, ${e.message}`);
    } else {
      console.error(`${name}: ${e.message}`);
      failed = true;
    }
  }
}
console.log(failed ? 'done, with errors' : 'done');
process.exit(failed ? 1 : 0);
