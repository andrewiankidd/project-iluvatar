// How the media apps find each other, through their APIs (wiring.yaml).
// Adds what's missing and leaves what's there alone, so it can run again and
// again, and the UI's own changes stay. One indexer only, the Internet Archive
// (public domain and openly licensed films); any other is the UI's choice.
//
//   Sonarr, Radarr   root folder under /data/media, qBittorrent as download client
//   Prowlarr         Sonarr and Radarr as applications (it pushes indexers to
//                    them), the Internet Archive as an indexer, and its
//                    searches through gluetun's proxy (Mullvad)
//   Seerr            Sonarr and Radarr, once its first-run wizard is done
//   Radarr           a Letterboxd watchlist as a list (ARDA_LETTERBOXD_USER)
//   Chaptarr         ebook and audiobook root folders, qBittorrent, and
//                    Prowlarr's book indexers as Torznab feeds
//   Grimmory         a library each for books, audiobooks, comics, manga
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
  chaptarr: { url: `http://chaptarr.${ns}:8789`, api: 'v1' },
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

// Three tries, 3s apart: a new pod is let through a NetworkPolicy
// (qBittorrent's) only a moment after it starts, once kube-router sees it.
async function up(url) {
  for (let i = 0; i < 3; i++) {
    try {
      if ((await fetch(url, { signal: AbortSignal.timeout(10000) })).ok) return true;
    } catch {}
    await new Promise((r) => setTimeout(r, 3000));
  }
  return false;
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
  // Files renamed to the standard format (Title (Year), S01E02), which Plex
  // and Jellyfin match on; off by default, which keeps a download's own name.
  const naming = await call(app, 'GET', '/config/naming');
  const renameKey = app === 'sonarr' ? 'renameEpisodes' : 'renameMovies';
  if (!naming[renameKey]) {
    await call(app, 'PUT', `/config/naming/${naming.id}`, { ...naming, [renameKey]: true });
    console.log(`${app}: renaming on`);
  }
  const clients = await call(app, 'GET', '/downloadclient');
  if (!clients.some((c) => c.implementation === 'QBittorrent')) {
    // Sonarr and Radarr test a new download client and refuse one they can't
    // reach; qBittorrent is down until its VPN has a key. The next run adds it.
    if (!(await up(`http://qbittorrent.${ns}:8080/api/v2/app/version`))) {
      console.log(`${app}: qBittorrent not up yet (no VPN key?); added once it is`);
      return;
    }
    const schema = await call(app, 'GET', '/downloadclient/schema');
    const client = fromSchema(schema, 'QBittorrent', 'qBittorrent', {
      host: `qbittorrent.${ns}`,
      port: 8080,
      [app === 'sonarr' ? 'tvCategory' : 'movieCategory']: category,
    }, { protocol: 'torrent', priority: 1 });
    await call(app, 'POST', '/downloadclient', client);
    console.log(`${app}: qBittorrent added`);
  }
}

async function prowlarr() {
  // Searches leave through Mullvad, as qBittorrent does: gluetun's HTTP proxy
  // (qbittorrent.yaml). The cluster's own names go direct.
  const host = await call('prowlarr', 'GET', '/config/host');
  const proxy = {
    proxyEnabled: true,
    proxyType: 'http',
    proxyHostname: `qbittorrent.${ns}`,
    proxyPort: 8888,
    proxyBypassFilter: '*.svc,*.svc.cluster.local,localhost',
    proxyBypassLocalAddresses: true,
  };
  if (Object.entries(proxy).some(([k, v]) => host[k] !== v)) {
    await call('prowlarr', 'PUT', `/config/host/${host.id}`, { ...host, ...proxy });
    console.log('prowlarr: searches through the VPN proxy');
  }
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
  // The Internet Archive: public, no account, and only what it may host
  // (public domain, openly licensed). Its torrents have archive.org as a web
  // seed, so they download with no peers: Mullvad gives no incoming port.
  const indexers = await call('prowlarr', 'GET', '/indexer');
  if (!indexers.some((i) => i.definitionName === 'internetarchive')) {
    const iSchema = await call('prowlarr', 'GET', '/indexer/schema');
    const ia = structuredClone(iSchema.find((s) => s.definitionName === 'internetarchive'));
    if (!ia) throw new Error('no internetarchive in the indexer schema');
    await call('prowlarr', 'POST', '/indexer', { ...ia, enable: true, appProfileId: 1, priority: 25 });
    console.log('prowlarr: Internet Archive added');
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

// Radarr follows a Letterboxd watchlist, through letterboxd-list
// (letterboxd.yaml): a film added there is added here and searched for.
// Kept pointing at the user in .env; other lists are the UI's.
async function letterboxd() {
  const user = process.env.LETTERBOXD_USER;
  if (!user) return;
  const url = `http://letterboxd-list.${ns}:5000/${encodeURIComponent(user)}/watchlist/?errorOnEmpty=false`;
  const name = 'Letterboxd watchlist';
  const lists = await call('radarr', 'GET', '/importlist');
  const mine = lists.find((l) => l.name === name);
  if (mine) {
    const field = mine.fields.find((f) => f.name === 'url');
    if (field.value === url) return;
    field.value = url;
    await call('radarr', 'PUT', `/importlist/${mine.id}`, mine);
    console.log(`radarr: ${name} now ${user}'s`);
    return;
  }
  const schema = await call('radarr', 'GET', '/importlist/schema');
  const profiles = await call('radarr', 'GET', '/qualityprofile');
  const profile = profiles.find((p) => p.name === 'HD - 720p/1080p') ?? profiles[0];
  // Import lists are switched on by `enabled` (not `enable`, as
  // fromSchema sets). No search on add: a watchlist of hundreds would be a
  // search each at once; Radarr's feed check (RSS) grabs as releases appear.
  const list = fromSchema(schema, 'RadarrListImport', name, { url }, {
    enabled: true,
    enableAuto: true,
    searchOnAdd: false,
    monitor: 'movieOnly',
    minimumAvailability: 'released',
    qualityProfileId: profile.id,
    rootFolderPath: apps.radarr.root,
  });
  await call('radarr', 'POST', '/importlist', list);
  console.log(`radarr: ${name} added (${user}, profile "${profile.name}")`);
}

// Chaptarr: a root folder each for ebooks and audiobooks, qBittorrent with a
// category each, and Prowlarr's book indexers as Torznab feeds. Those are
// what Prowlarr's own Readarr sync would add, done here instead because that
// sync fails against Chaptarr (Chaptarr#84). An indexer added in Prowlarr
// later reaches Chaptarr on the next run.
async function chaptarr() {
  const folders = await call('chaptarr', 'GET', '/rootfolder');
  const qualities = await call('chaptarr', 'GET', '/qualityprofile');
  const metadatas = await call('chaptarr', 'GET', '/metadataprofile');
  const id = (list, name) => (list.find((p) => p.name === name) ?? list[0]).id;
  for (const f of [
    { name: 'Ebooks', path: '/data/media/books', folderType: 2,
      ebookQualityProfileId: id(qualities, 'E-Book'), ebookMetadataProfileId: id(metadatas, 'Ebook Default') },
    { name: 'Audiobooks', path: '/data/media/audiobooks', folderType: 1,
      audiobookQualityProfileId: id(qualities, 'Audiobook'), audiobookMetadataProfileId: id(metadatas, 'Audiobook Default') },
  ]) {
    if (folders.some((r) => r.path.replace(/\/$/, '') === f.path)) continue;
    await call('chaptarr', 'POST', '/rootfolder', { ...f, isCalibreLibrary: false, defaultTags: [] });
    console.log(`chaptarr: root folder ${f.path} added`);
  }
  const clients = await call('chaptarr', 'GET', '/downloadclient');
  if (!clients.some((c) => c.implementation === 'QBittorrent')) {
    if (!(await up(`http://qbittorrent.${ns}:8080/api/v2/app/version`))) {
      console.log('chaptarr: qBittorrent not up yet (no VPN key?); added once it is');
    } else {
      const schema = await call('chaptarr', 'GET', '/downloadclient/schema');
      const client = fromSchema(schema, 'QBittorrent', 'qBittorrent', {
        host: `qbittorrent.${ns}`, port: 8080, ebookCategory: 'books', audiobookCategory: 'audiobooks',
      }, { protocol: 'torrent', priority: 1 });
      await call('chaptarr', 'POST', '/downloadclient', client);
      console.log('chaptarr: qBittorrent added');
    }
  }
  // Prowlarr's indexers that carry books (7000s) or audiobooks (3030).
  const bookCats = (cats) => cats.flatMap((c) => [c, ...(c.subCategories ?? [])]).map((c) => c.id)
    .filter((id) => (id >= 7000 && id < 8000) || id === 3030);
  const prowlarrIndexers = await call('prowlarr', 'GET', '/indexer');
  const existing = await call('chaptarr', 'GET', '/indexer');
  const schema = await call('chaptarr', 'GET', '/indexer/schema');
  for (const ix of prowlarrIndexers) {
    const cats = bookCats(ix.capabilities?.categories ?? []);
    if (!ix.enable || !cats.length || ix.protocol !== 'torrent') continue;
    const baseUrl = `${apps.prowlarr.url}/${ix.id}/`;
    if (existing.some((e) => e.fields.find((f) => f.name === 'baseUrl')?.value === baseUrl)) continue;
    const item = fromSchema(schema, 'Torznab', `${ix.name} (Prowlarr)`, {
      baseUrl, apiPath: '/api', apiKey: key('prowlarr'), categories: cats,
    }, { protocol: 'torrent', enableRss: true, enableAutomaticSearch: true, enableInteractiveSearch: true, priority: 25 });
    await call('chaptarr', 'POST', '/indexer?forceSave=true', item);
    console.log(`chaptarr: indexer ${ix.name} added (from Prowlarr)`);
  }
}

// Grimmory: a library per type, over the folders Chaptarr and Comicarr fill.
// It has no API key: it trusts the Dex login's headers (grimmory.yaml), so
// the job signs in as the lab's admin the same way.
async function grimmory() {
  const base = 'http://grimmory.media.svc:6060/api/v1';
  let res;
  try {
    res = await fetch(`${base}/auth/remote`, {
      headers: {
        'X-Auth-Request-User': 'admin@kidd.network',
        'X-Auth-Request-Email': 'admin@kidd.network',
        'X-Auth-Request-Preferred-Username': 'admin',
        'X-Auth-Request-Groups': 'admins,users',
      },
      signal: AbortSignal.timeout(20000),
    });
  } catch (e) {
    throw new NotUp(`grimmory not reachable (${e.cause?.code ?? e.message})`);
  }
  if (!res.ok) throw new NotUp(`grimmory starting (${res.status})`);
  const { accessToken } = await res.json();
  const g = async (method, path, body) => {
    const r = await fetch(`${base}${path}`, {
      method,
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: body && JSON.stringify(body),
      signal: AbortSignal.timeout(20000),
    });
    const text = await r.text();
    if (!r.ok) throw new Error(`grimmory ${method} ${path}: ${r.status} ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : null;
  };
  const libraries = await g('GET', '/libraries');
  const have = new Set(libraries.flatMap((l) => (l.paths ?? []).map((p) => p.path.replace(/\/$/, ''))));
  for (const [name, dir, icon] of [
    ['Books', 'books', 'book-open'], ['Audiobooks', 'audiobooks', 'headphones'],
    ['Comics', 'comics', 'book-image'], ['Manga', 'manga', 'scroll-text'],
  ]) {
    const path = `/data/media/${dir}`;
    if (have.has(path)) continue;
    await g('POST', '/libraries', { name, icon, iconType: 'LUCIDE', paths: [{ path }], watch: true });
    console.log(`grimmory: library ${name} added`);
  }
  // Its folder watching misses what Chaptarr and Comicarr write from other
  // nodes (the volume is NFS), so its "Sync Library Files" task, which finds
  // new files, runs every 15 minutes instead of nightly.
  const sync = (await g('GET', '/tasks')).find((t) => t.taskType === 'SYNC_LIBRARY_FILES');
  const every15 = '0 */15 * * * *';
  if (sync?.cronConfig?.cronExpression !== every15 || !sync?.cronConfig?.enabled) {
    await g('PATCH', '/tasks/SYNC_LIBRARY_FILES/cron', { cronExpression: every15, enabled: true });
    console.log('grimmory: library sync every 15 minutes');
  }
}

let failed = false;
for (const [name, step] of [['sonarr', () => arr('sonarr')], ['radarr', () => arr('radarr')], ['prowlarr', prowlarr], ['seerr', seerr], ['letterboxd', letterboxd], ['chaptarr', chaptarr], ['grimmory', grimmory]]) {
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
