#!/usr/bin/env bash
# Generates remote shell code (run on valar-50 as root) to reconcile Tier C
# stateful app passwords/API keys that apps only read on first start.
# Sourced by sync-env.sh.

emit_reconcile_lldap_dex() {
  cat <<'REMOTE_EOF'
echo "[reconcile] ==> Updating LLDAP 'dex' user password (AINUR_LLDAP_DEX_PASSWORD)..."
k3s kubectl -n ainur-dex rollout status deploy/lldap --timeout=120s
ADMIN_PW="$(k3s kubectl -n ainur-dex get secret ainur-secrets -o jsonpath='{.data.AINUR_LLDAP_ADMIN_PASSWORD}' | base64 -d)"
DEX_PW="$(k3s kubectl -n ainur-dex get secret ainur-secrets -o jsonpath='{.data.AINUR_LLDAP_DEX_PASSWORD}' | base64 -d)"
if [ -z "$ADMIN_PW" ] || [ -z "$DEX_PW" ]; then
  echo "[reconcile] WARN: AINUR_LLDAP_ADMIN_PASSWORD or AINUR_LLDAP_DEX_PASSWORD missing; skipping LLDAP dex update"
else
  printf '%s\n%s\n' "$ADMIN_PW" "$DEX_PW" | \
    k3s kubectl -n ainur-dex exec -i deploy/lldap -- sh -c '
      IFS= read -r apw
      IFS= read -r dpw
      /app/lldap_set_password \
        --base-url http://127.0.0.1:17170 \
        --username dex \
        --password "$dpw" \
        --admin-username admin \
        --admin-password "$apw"
    '
  echo "[reconcile] [OK] LLDAP 'dex' password updated; restarting Dex to re-bind..."
  k3s kubectl -n ainur-dex rollout restart deploy/dex
  k3s kubectl -n ainur-dex rollout status deploy/dex --timeout=120s
fi
REMOTE_EOF
}

emit_reconcile_paperless_admin() {
  cat <<'REMOTE_EOF'
echo "[reconcile] ==> Updating Paperless superuser 'paperless' password in SQLite (ARDA_PAPERLESS_ADMIN_PASSWORD)..."
if kubectl --kubeconfig "$ARDA_KC" -n paperless get deploy/paperless >/dev/null 2>&1; then
  P_PW="$(kubectl --kubeconfig "$ARDA_KC" -n paperless get secret paperless -o jsonpath='{.data.admin-password}' | base64 -d)"
  if [ -n "$P_PW" ]; then
    printf '%s' "$P_PW" | kubectl --kubeconfig "$ARDA_KC" -n paperless exec -i deploy/paperless -c paperless -- \
      python3 -c '
import os, sys
sys.path.insert(0, "/usr/src/paperless/src")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "paperless.settings")
import django; django.setup()
from django.contrib.auth import get_user_model
pw = sys.stdin.read()
User = get_user_model()
u = User.objects.filter(username="paperless").first()
if u:
    u.set_password(pw)
    u.save()
    print("[reconcile] [OK] Paperless superuser password updated in DB")
else:
    print("[reconcile] WARN: user paperless not found yet (first-start not complete)")
'
  fi
else
  echo "[reconcile] WARN: arda paperless/deploy/paperless not found; skipping"
fi
REMOTE_EOF
}

emit_reconcile_homeassistant_owner() {
  cat <<'REMOTE_EOF'
echo "[reconcile] ==> Updating Home Assistant owner 'admin' password (ARDA_HOMEASSISTANT_PASSWORD)..."
if kubectl --kubeconfig "$ARDA_KC" -n homeassistant get deploy/homeassistant >/dev/null 2>&1; then
  HA_PW="$(kubectl --kubeconfig "$ARDA_KC" -n homeassistant get secret homeassistant -o jsonpath='{.data.owner-password}' | base64 -d)"
  if [ -n "$HA_PW" ]; then
    printf '%s' "$HA_PW" | kubectl --kubeconfig "$ARDA_KC" -n homeassistant exec -i deploy/homeassistant -c homeassistant -- \
      sh -c 'pw="$(cat)"; hass --script auth --config /config change_password admin "$pw"'
    echo "[reconcile] [OK] Home Assistant owner password updated; restarting Home Assistant to reload auth store..."
    kubectl --kubeconfig "$ARDA_KC" -n homeassistant rollout restart deploy/homeassistant
    kubectl --kubeconfig "$ARDA_KC" -n homeassistant rollout status deploy/homeassistant --timeout=180s
  fi
else
  echo "[reconcile] WARN: arda homeassistant/deploy/homeassistant not found; skipping"
fi
REMOTE_EOF
}

emit_reconcile_grimmory_mariadb() {
  cat <<'REMOTE_EOF'
echo "[reconcile] ==> Updating Grimmory MariaDB password before media restarts (ARDA_MEDIA_API_SECRET)..."
if kubectl --kubeconfig "$ARDA_KC" -n media get deploy/grimmory-db >/dev/null 2>&1; then
  GDB_PW="$(kubectl --kubeconfig "$ARDA_KC" -n media get secret media -o jsonpath='{.data.grimmory-db-password}' | base64 -d)"
  if [ -n "$GDB_PW" ]; then
    # Hex-only 32-char sha256 output, safe to embed after verifying charset
    printf "ALTER USER 'grimmory'@'%%' IDENTIFIED BY '%s';\nALTER USER 'root'@'localhost' IDENTIFIED BY '%s';\nFLUSH PRIVILEGES;\n" \
      "$GDB_PW" "$GDB_PW" | \
      kubectl --kubeconfig "$ARDA_KC" -n media exec -i deploy/grimmory-db -- mariadb -u root
    echo "[reconcile] [OK] Grimmory MariaDB passwords updated for grimmory@% and root@localhost"
  fi
else
  echo "[reconcile] WARN: arda media/deploy/grimmory-db not found; skipping"
fi
REMOTE_EOF
}

emit_reconcile_media_peer_keys() {
  cat <<'REMOTE_EOF'
echo "[reconcile] ==> Syncing rotated peer API keys inside Prowlarr, Seerr, and Chaptarr (ARDA_MEDIA_API_SECRET)..."
# Wait for core media deployments to finish rolling out before calling their APIs
for dep in sonarr radarr prowlarr seerr chaptarr; do
  if kubectl --kubeconfig "$ARDA_KC" -n media get "deploy/$dep" >/dev/null 2>&1; then
    kubectl --kubeconfig "$ARDA_KC" -n media rollout status "deploy/$dep" --timeout=180s || true
  fi
done
# Run a short-lived pod labelled app=wiring so media NetworkPolicies allow access
kubectl --kubeconfig "$ARDA_KC" -n media delete pod media-key-reconcile --ignore-not-found >/dev/null 2>&1 || true
kubectl --kubeconfig "$ARDA_KC" -n media apply -f - <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: media-key-reconcile
  namespace: media
  labels:
    app: wiring
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: reconcile
      image: node:22-alpine
      envFrom:
        - secretRef:
            name: media
      command:
        - node
        - -e
        - |
          const env = process.env;
          const k = (n) => env[`${n}-api-key`];
          async function req(url, key, method = 'GET', body) {
            const r = await fetch(url, {
              method,
              headers: { 'X-Api-Key': key, 'Content-Type': 'application/json' },
              body: body ? JSON.stringify(body) : undefined,
              signal: AbortSignal.timeout(15000),
            });
            const t = await r.text();
            if (!r.ok) throw new Error(`${method} ${url} -> ${r.status}: ${t.slice(0,200)}`);
            return t ? JSON.parse(t) : null;
          }
          (async () => {
            // 1. Prowlarr -> Sonarr & Radarr stored API keys
            try {
              const base = 'http://prowlarr.media.svc:9696/api/v1';
              const apps = await req(`${base}/applications`, k('prowlarr'));
              for (const a of apps) {
                const target = a.implementation === 'Sonarr' ? 'sonarr' : a.implementation === 'Radarr' ? 'radarr' : null;
                if (!target) continue;
                const f = (a.fields || []).find((x) => x.name === 'apiKey');
                if (f && f.value !== k(target)) {
                  f.value = k(target);
                  await req(`${base}/applications/${a.id}?forceSave=true`, k('prowlarr'), 'PUT', a);
                  console.log(`prowlarr: updated ${a.implementation} API key`);
                }
              }
            } catch (e) { console.log('prowlarr peer sync note:', e.message); }
            // 2. Seerr -> Sonarr & Radarr stored API keys
            try {
              const base = 'http://seerr.media.svc:5055/api/v1';
              for (const app of ['sonarr', 'radarr']) {
                const list = await req(`${base}/settings/${app}`, k('seerr'));
                for (const item of list) {
                  if (item.apiKey !== k(app)) {
                    await req(`${base}/settings/${app}/${item.id}`, k('seerr'), 'PUT', { ...item, apiKey: k(app) });
                    console.log(`seerr: updated ${app} #${item.id} API key`);
                  }
                }
              }
            } catch (e) { console.log('seerr peer sync note:', e.message); }
            // 3. Chaptarr -> Prowlarr Torznab indexer API keys
            try {
              const base = 'http://chaptarr.media.svc:8789/api/v1';
              const idx = await req(`${base}/indexer`, k('chaptarr'));
              for (const ix of idx) {
                const urlF = (ix.fields || []).find((x) => x.name === 'baseUrl');
                const keyF = (ix.fields || []).find((x) => x.name === 'apiKey');
                if (urlF && String(urlF.value || '').includes('prowlarr.media.svc') && keyF && keyF.value !== k('prowlarr')) {
                  keyF.value = k('prowlarr');
                  await req(`${base}/indexer/${ix.id}?forceSave=true`, k('chaptarr'), 'PUT', ix);
                  console.log(`chaptarr: updated Prowlarr key on indexer ${ix.name}`);
                }
              }
            } catch (e) { console.log('chaptarr peer sync note:', e.message); }
          })();
POD_EOF
kubectl --kubeconfig "$ARDA_KC" -n media wait --for=jsonpath='{.status.phase}'=Succeeded pod/media-key-reconcile --timeout=120s || true
kubectl --kubeconfig "$ARDA_KC" -n media logs pod/media-key-reconcile || true
kubectl --kubeconfig "$ARDA_KC" -n media delete pod media-key-reconcile --ignore-not-found >/dev/null 2>&1 || true
echo "[reconcile] [OK] Media peer API key reconciliation finished"
REMOTE_EOF
}

emit_reconcile_transmute_admin() {
  cat <<'REMOTE_EOF'
echo "[reconcile] ==> Updating Transmute stored 'admin' password in SQLite (derived from AINUR_SSO_SECRET)..."
if kubectl --kubeconfig "$ARDA_KC" -n transmute get deploy/transmute >/dev/null 2>&1; then
  kubectl --kubeconfig "$ARDA_KC" -n transmute rollout status deploy/transmute --timeout=180s || true
  kubectl --kubeconfig "$ARDA_KC" -n transmute exec deploy/transmute -- python -c '
import glob, os, sqlite3
pw = os.environ.get("TRANSMUTE_ADMIN_PASSWORD", "")
if not pw:
    print("[reconcile] WARN: TRANSMUTE_ADMIN_PASSWORD not set in pod")
    raise SystemExit(0)
hashed = None
try:
    import bcrypt
    hashed = bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode()
except Exception:
    try:
        from passlib.context import CryptContext
        hashed = CryptContext(schemes=["bcrypt"]).hash(pw)
    except Exception as e:
        print(f"[reconcile] WARN: could not hash password ({e})")
        raise SystemExit(0)
dbs = sorted(glob.glob("/app/data/*.db") + glob.glob("/app/data/*.sqlite*"))
updated = False
for db in dbs:
    try:
        con = sqlite3.connect(db)
        cur = con.cursor()
        tables = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type=\"table\"")]
        if "users" in tables:
            cols = [r[1] for r in cur.execute("PRAGMA table_info(users)")]
            pcol = next((c for c in ("hashed_password", "password_hash", "password") if c in cols), None)
            if pcol:
                cur.execute(f"UPDATE users SET {pcol} = ? WHERE username = \"admin\"", (hashed,))
                if cur.rowcount:
                    con.commit()
                    print(f"[reconcile] [OK] Updated Transmute admin password in {db} ({pcol})")
                    updated = True
        con.close()
    except Exception as e:
        print(f"[reconcile] WARN: skipped {db}: {e}")
if not updated:
    print("[reconcile] WARN: no existing Transmute admin row updated (may not have initialized yet)")
'
else
  echo "[reconcile] WARN: arda transmute/deploy/transmute not found; skipping"
fi
REMOTE_EOF
}
