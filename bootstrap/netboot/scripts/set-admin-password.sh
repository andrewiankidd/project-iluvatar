#!/usr/bin/env bash
# Sets the lab's admin password, yours: user admin in LLDAP, which is your
# Dex login (Argo CD, Grafana, Headlamp, Omni, the admin page, the
# oauth2-proxy sites, the apps' "Sign in with Dex") and lldap.kidd.network's,
# and admin in ntfy.
#
#   scripts/set-admin-password.sh             asks for it, twice
#   scripts/set-admin-password.sh --generate  makes one, and shows it once
#
# Two lines in .env: AINUR_LLDAP_ADMIN_PASSWORD, the password itself, which
# LLDAP sets as admin's at every start; and AINUR_DEX_ADMIN_HASH, its bcrypt
# hash, for ntfy. From there nothing is manual: the bootstrap VM's
# pi-secrets-pusher sees .env change and pushes it to ainur within a minute,
# ainur-secrets.sh updates the ainur-secrets Secret, and Reloader
# (src/manifests/ainur/reloader.yml) restarts LLDAP and ntfy, which read it at
# start. This waits until both take the new password, which is the whole
# chain working.
#
# Then: the ntfy app on your phone has the old password saved for
# ntfy.kidd.network; change it there.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/../.env}"
NTFY_URL="${NTFY_URL:-https://ntfy.kidd.network}"
LLDAP_URL="${LLDAP_URL:-https://lldap.kidd.network}"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE" >&2; exit 1; }

if [ "${1:-}" = --generate ]; then
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  echo "New admin password (shown once, keep it in your password manager):"
  echo "  $pw"
else
  read -rsp "New admin password: " pw; echo
  read -rsp "Again: " again; echo
  [ "$pw" = "$again" ] || { echo "they don't match" >&2; exit 1; }
  [ "${#pw}" -ge 12 ] || { echo "at least 12 characters, please" >&2; exit 1; }
fi
# .env single-quotes it.
case "$pw" in *"'"*) echo "no single quotes in it, please" >&2; exit 1 ;; esac

# bcrypt, cost 10. The password goes over stdin, never on a command line.
bcrypt() {
  if command -v htpasswd >/dev/null; then htpasswd -niBC 10 admin
  else docker pull -q httpd:2.4-alpine >/dev/null
       docker run --rm -i httpd:2.4-alpine htpasswd -niBC 10 admin
  fi
}
hash="$(printf '%s\n' "$pw" | bcrypt | cut -d: -f2- | tr -d '\r\n')"
case "$hash" in '$2'?'$10$'*) ;; *) echo "hashing failed" >&2; exit 1 ;; esac

# Replace the lines in place (cat >, not mv: the pusher has .env's directory
# mounted, and the file keeps its permissions).
tmp="$(mktemp)"
trap 'rm -f "${tmp:?}" "${ca:-}"' EXIT
H="$hash" PW="$pw" awk '
  BEGIN { q = "'\''"
          hl = "AINUR_DEX_ADMIN_HASH=" q ENVIRON["H"] q
          pl = "AINUR_LLDAP_ADMIN_PASSWORD=" q ENVIRON["PW"] q }
  /^AINUR_DEX_ADMIN_HASH=/ { print hl; h = 1; next }
  /^AINUR_LLDAP_ADMIN_PASSWORD=/ { print pl; p = 1; next }
  { print }
  END { if (!h) print hl; if (!p) print pl }
' "$ENV_FILE" > "$tmp"
cat "$tmp" > "$ENV_FILE"
echo "AINUR_LLDAP_ADMIN_PASSWORD and AINUR_DEX_ADMIN_HASH updated in $(basename "$ENV_FILE")."

# Wait for both to take it. Their certificates are the lab CA's, in .env too.
ca="$(mktemp)"
sed -n 's/^AINUR_LAB_CA_CRT=//p' "$ENV_FILE" | tr -d "'\"" | base64 -d > "$ca" 2>/dev/null || true
# --ssl-no-revoke: Windows' curl otherwise fails on the lab CA, which has no
# revocation list; other curls ignore it.
cacert=(--cacert "$ca" --ssl-no-revoke); [ -s "$ca" ] || cacert=(-k)
# curl config and JSON quoting alike: backslashes and double quotes escaped.
esc="${pw//\\/\\\\}"; esc="${esc//\"/\\\"}"
echo "Waiting for ainur to pick it up (pusher, then a restart of LLDAP and ntfy)..."
ntfy=no lldap=no
for _ in $(seq 60); do
  # The credentials over stdin (curl -K -, --data-binary @-), never on the
  # command line.
  if [ $ntfy = no ] && [ "$(printf 'user = "admin:%s"\n' "$esc" \
      | curl -sS -o /dev/null -w '%{http_code}' -K - "${cacert[@]}" \
          "$NTFY_URL/v1/account" 2>/dev/null || true)" = 200 ]; then
    ntfy=yes; echo "  ntfy takes it"
  fi
  if [ $lldap = no ] && [ "$(printf '{"username":"admin","password":"%s"}' "$esc" \
      | curl -sS -o /dev/null -w '%{http_code}' "${cacert[@]}" \
          -H 'Content-Type: application/json' --data-binary @- \
          "$LLDAP_URL/auth/simple/login" 2>/dev/null || true)" = 200 ]; then
    lldap=yes; echo "  LLDAP takes it: your Dex login"
  fi
  if [ $ntfy = yes ] && [ $lldap = yes ]; then
    echo "Done. Sign in anywhere as admin with it."
    echo "Change it in the ntfy app on your phone (ntfy.kidd.network)."
    exit 0
  fi
  sleep 5
done
echo "Not taken after 5 minutes (ntfy: $ntfy, LLDAP: $lldap). Is pi-secrets-pusher" >&2
echo "running (docker compose logs pi-secrets-pusher), and Reloader on ainur?" >&2
exit 1
