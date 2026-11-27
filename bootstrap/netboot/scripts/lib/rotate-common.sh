#!/usr/bin/env bash
# Shared library for project-iluvatar secret rotation & live-cluster sync scripts.
# Sourced by rotate.sh, sync-env.sh, rotate-push-key.sh, rotate-k3s-tokens.sh,
# and rotate-restic-password.sh.

# --- Colors & Verbose Logging ----------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED=''
fi

_ts() { date '+%H:%M:%S'; }

banner() {
  printf '\n%s%s========================================================================%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '%s%s  %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
  if [ -n "${2:-}" ]; then
    printf '%s  %s%s\n' "$C_DIM" "$2" "$C_RESET"
  fi
  printf '%s%s========================================================================%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
}

section() {
  printf '\n%s%s--- %s ---%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"
}

step() {
  printf '%s[%s]%s %s==>%s %s%s%s\n' "$C_DIM" "$(_ts)" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}

info() {
  printf '%s[%s]%s   %s\n' "$C_DIM" "$(_ts)" "$C_RESET" "$*"
}

detail() {
  printf '%s[%s]     %s%s\n' "$C_DIM" "$(_ts)" "$*" "$C_RESET"
}

ok() {
  printf '%s[%s]%s %s[OK]%s %s\n' "$C_DIM" "$(_ts)" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"
}

warn() {
  printf '%s[%s]%s %s[WARN]%s %s\n' "$C_DIM" "$(_ts)" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2
}

err() {
  printf '%s[%s]%s %s[ERROR]%s %s\n' "$C_DIM" "$(_ts)" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2
}

# --- Paths & Defaults ------------------------------------------------------
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETBOOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$NETBOOT_DIR/.env}"

# --- Safe .env Helpers (never prints raw secret values) --------------------
require_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    err "Cannot find .env file at: $ENV_FILE"
    info "Set ENV_FILE=/path/to/.env or copy bootstrap/netboot/.env.example to bootstrap/netboot/.env"
    exit 1
  fi
}

# Read a single variable from .env without executing arbitrary shell code.
# Strips matching outer single or double quotes and trailing CR.
env_get() {
  local key="$1" file="${2:-$ENV_FILE}" line val
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | tr -d '\r' || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  case "$val" in
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
  esac
  printf '%s' "$val"
}

# List all non-empty AINUR_* and ARDA_* key names defined in .env.
env_list_cluster_keys() {
  local file="${1:-$ENV_FILE}"
  sed -nE 's/^((AINUR|ARDA)_[A-Z0-9_]+)=.*$/\1/p' "$file" | sort -u
}

# Short non-reversible fingerprint for safe verbose diffs (first 10 hex chars of SHA-256).
short_hash() {
  local val="$1"
  if [ -z "$val" ]; then
    printf '(empty)'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$val" | sha256sum | cut -c1-10
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$val" | shasum -a 256 | cut -c1-10
  else
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:10])' <<< "$val"
  fi
}

# Create a timestamped backup of .env (gitignored via bootstrap/netboot/.env.bak.*)
env_backup() {
  local ts bak
  ts="$(date '+%Y%m%d-%H%M%S')"
  bak="${ENV_FILE}.bak.${ts}"
  umask 077
  cp "$ENV_FILE" "$bak"
  chmod 600 "$bak" 2>/dev/null || true
  ok "Backed up .env to $(basename "$bak")"
  printf '%s' "$bak"
}

# Safely update or append KEY=VALUE in .env in place (preserves permissions & LF endings).
# Single-quotes values containing $, spaces, &, or quotes (rejecting embedded single quotes).
env_set() {
  local key="$1" val="$2" file="${3:-$ENV_FILE}" tmp quoted
  case "$val" in
    *"'"*)
      err "Value for $key contains a single quote; refusing to write unsafe .env syntax."
      return 1
      ;;
  esac
  if printf '%s' "$val" | grep -qE '[\$\s&;\|<>()`"\\]'; then
    quoted="'${val}'"
  else
    quoted="$val"
  fi
  tmp="$(mktemp)"
  KEY="$key" LINE="${key}=${quoted}" awk '
    BEGIN { k = ENVIRON["KEY"] "="; repl = ENVIRON["LINE"]; done = 0 }
    index($0, k) == 1 { if (!done) { print repl; done = 1 } next }
    { print }
    END { if (!done) print repl }
  ' "$file" > "$tmp"
  # Keep original inode/permissions (matches set-admin-password.sh)
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Cryptographically random generators (no single quotes, safe in .env and shells)
rand_alnum() {
  local len="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" || true
}

rand_hex() {
  local bytes="${1:-24}"
  head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

rand_ntfy_token() {
  # ntfy requires: tk_ + 29 lowercase alphanumeric chars
  printf 'tk_%s' "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 29 || true)"
}

# --- Confirmation Prompts --------------------------------------------------
# One-time confirmation for Tiers B, C, and D.
confirm_tier() {
  local tier="$1" title="$2" count="$3"
  printf '\n%s%s[CONFIRMATION — TIER %s: %s (%s key(s))]%s\n' \
    "$C_BOLD" "$C_YELLOW" "$tier" "$title" "$count" "$C_RESET"
  local ans=""
  read -r -p "Proceed with ALL listed Tier $tier changes? [y/N]: " ans
  case "${ans,,}" in
    y|yes)
      ok "Tier $tier approved by user."
      return 0
      ;;
    *)
      warn "Tier $tier skipped by user."
      return 1
      ;;
  esac
}

# Individual confirmation for EVERY Tier E (highest-risk) entry.
# Requires typing the exact variable name so accidental 'y'/Enter is impossible.
confirm_tier_e_entry() {
  local var="$1" impact="$2"
  printf '\n%s%s[HIGHEST-TIER INDIVIDUAL CONFIRMATION — TIER E: %s]%s\n' \
    "$C_BOLD" "$C_RED" "$var" "$C_RESET"
  printf '  %sImpact:%s %s\n' "$C_YELLOW" "$C_RESET" "$impact"
  local ans=""
  read -r -p "Type the exact name '$var' to proceed (or press Enter to skip): " ans
  if [ "$ans" = "$var" ]; then
    ok "Confirmed Tier E entry: $var"
    return 0
  else
    warn "Skipped Tier E entry: $var"
    return 1
  fi
}

# --- Complete Phase 1 Variable Catalog -------------------------------------
# Tiers:
#   B = Live-rotatable via Secret sync + rollout restart
#   C = Live-rotatable WITH in-app DB / API reconciliation
#   D = Pi host / k3s cluster-level credentials (special procedure)
#   E = Encryption / trust roots (highest tier — individual confirmation)
#   A = Bootstrap / VM / host build only (not pushed to cluster)
var_tier() {
  case "$1" in
    AINUR_LLDAP_KEY_SEED|ARDA_VOLSYNC_PASSWORD|AINUR_LAB_CA_CRT|AINUR_LAB_CA_KEY)
      echo "E" ;;
    AINUR_PUSH_KEY|AINUR_PUSH_PUBKEY|AINUR_K3S_TOKEN|AINUR_K3S_AGENT_TOKEN)
      echo "D" ;;
    AINUR_LLDAP_DEX_PASSWORD|ARDA_PAPERLESS_ADMIN_PASSWORD|ARDA_HOMEASSISTANT_PASSWORD|ARDA_MEDIA_API_SECRET)
      echo "C" ;;
    AINUR_*|ARDA_*)
      echo "B" ;;
    *)
      echo "A" ;;
  esac
}

var_cluster() {
  case "$1" in
    AINUR_OIDC_CLIENT_SECRET|AINUR_SSO_SECRET)
      echo "ainur + arda" ;;
    ARDA_BACKUP_ACCESS_KEY_ID|ARDA_BACKUP_SECRET_ACCESS_KEY|ARDA_BACKUP_ENDPOINT|ARDA_VOLSYNC_PASSWORD|ARDA_CLOUDFLARE_API_TOKEN|ARDA_UNIFI_API_KEY)
      echo "ainur + arda" ;;
    ARDA_CLOUDFLARE_ACCOUNT_ID|ARDA_CLOUDFLARE_ACCESS_EMAILS|ARDA_UNIFI_URL)
      echo "ainur" ;;
    AINUR_*)
      echo "ainur" ;;
    ARDA_*)
      echo "arda" ;;
    *)
      echo "host/vm" ;;
  esac
}

var_needs_arda_bootstrap() {
  case "$1" in
    AINUR_OIDC_CLIENT_SECRET|AINUR_SSO_SECRET|ARDA_*)
      # These 3 ARDA_* vars are only consumed by CronJobs on ainur itself
      case "$1" in
        ARDA_CLOUDFLARE_ACCOUNT_ID|ARDA_CLOUDFLARE_ACCESS_EMAILS|ARDA_UNIFI_URL) return 1 ;;
      esac
      return 0 ;;
    *)
      return 1 ;;
  esac
}

var_summary() {
  case "$1" in
    AINUR_DEX_ADMIN_HASH) echo "ntfy admin bcrypt hash (ainur-monitoring/ntfy; Reloader)" ;;
    AINUR_LLDAP_ADMIN_PASSWORD) echo "LLDAP admin password (ainur-dex/lldap; forced reset on restart via Reloader)" ;;
    AINUR_LLDAP_DEX_PASSWORD) echo "LLDAP read-only 'dex' bind password (requires LLDAP user update + Dex restart)" ;;
    AINUR_LLDAP_JWT_SECRET) echo "LLDAP web session JWT signing key (ainur-dex/lldap; Reloader)" ;;
    AINUR_LLDAP_KEY_SEED) echo "LLDAP SQLite password-encryption seed (DESTRUCTIVE: invalidates all user passwords)" ;;
    AINUR_OIDC_CLIENT_SECRET) echo "Shared Dex OIDC client secret (Dex, Argo CD, Headlamp, Omni, Homepage, arda oauth2-proxy, Paperless)" ;;
    AINUR_SSO_SECRET) echo "Shared SSO cookie seed + Transmute auth/admin + CrowdSec LAPI/bouncer keys (both clusters)" ;;
    AINUR_HOMEPAGE_AUTH_SECRET) echo "DEPRECATED / UNUSED (orphaned when Homepage moved behind oauth2-proxy)" ;;
    AINUR_NTFY_TOKEN) echo "Alertmanager -> ntfy bearer token (ntfy + alertmanager)" ;;
    AINUR_DEADMAN_URL) echo "Alertmanager Watchdog deadman webhook URL (alertmanager)" ;;
    AINUR_LAB_CA_CRT) echo "Lab Root CA certificate (DESTRUCTIVE: trusted by k3s OIDC, cert-manager, Talos nodes, devices)" ;;
    AINUR_LAB_CA_KEY) echo "Lab Root CA private key (DESTRUCTIVE: must match AINUR_LAB_CA_CRT)" ;;
    AINUR_PUSH_KEY) echo "Private Ed25519 SSH key for pushing secrets to Pis (use rotate-push-key.sh)" ;;
    AINUR_PUSH_PUBKEY) echo "Public Ed25519 SSH key authorized on Pis (use rotate-push-key.sh)" ;;
    AINUR_K3S_TOKEN) echo "k3s server join token on valar-50 (use rotate-k3s-tokens.sh)" ;;
    AINUR_K3S_AGENT_TOKEN) echo "k3s agent join token for netbooted Pis (use rotate-k3s-tokens.sh)" ;;
    ARDA_CLOUDFLARE_ACCOUNT_ID) echo "Cloudflare account ID for Zero Trust Access sync (ainur arda-tunnel CronJob)" ;;
    ARDA_CLOUDFLARE_API_TOKEN) echo "Cloudflare API token (ainur arda-tunnel; arda external-dns, external-dns-tunnel, ddns)" ;;
    ARDA_CLOUDFLARE_ACCESS_EMAILS) echo "Cloudflare Zero Trust allowed emails (ainur arda-tunnel CronJob)" ;;
    ARDA_CLOUDFLARE_TUNNEL_TOKEN) echo "Cloudflare Tunnel connector token (arda cloudflared)" ;;
    ARDA_UNIFI_API_KEY) echo "UniFi OS API key (ainur unifi CronJob; arda external-dns-lan)" ;;
    ARDA_UNIFI_URL) echo "UniFi OS console URL (ainur unifi CronJob)" ;;
    ARDA_MINECRAFT_WHITELIST) echo "Minecraft player UUID whitelist (arda minecraft servers)" ;;
    ARDA_MINECRAFT_BUILDERS) echo "Minecraft creative builder UUIDs (arda minecraft servers)" ;;
    ARDA_DRAGONWILDS_OWNER_ID) echo "Dragonwilds owner player ID (arda dragonwilds)" ;;
    ARDA_DRAGONWILDS_ADMIN_PASSWORD) echo "Dragonwilds server management password (arda dragonwilds)" ;;
    ARDA_DRAGONWILDS_WORLD_PASSWORD) echo "Dragonwilds world join password (arda dragonwilds)" ;;
    ARDA_BACKUP_ACCESS_KEY_ID) echo "R2 backup access key ID (ainur omni/lldap backups; arda volsync + backrest)" ;;
    ARDA_BACKUP_SECRET_ACCESS_KEY) echo "R2 backup secret key (ainur omni/lldap backups; arda volsync + backrest)" ;;
    ARDA_BACKUP_ENDPOINT) echo "R2 S3 endpoint URL (ainur omni/lldap backups; arda volsync + backrest)" ;;
    ARDA_VOLSYNC_PASSWORD) echo "Restic encryption password for ALL backups (DESTRUCTIVE without restic key add/remove)" ;;
    ARDA_GDRIVE_TOKEN) echo "Google Drive rclone OAuth token JSON (arda volsync + backrest)" ;;
    ARDA_GDRIVE_CLIENT_ID) echo "Google Drive OAuth client ID (arda volsync + backrest)" ;;
    ARDA_GDRIVE_CLIENT_SECRET) echo "Google Drive OAuth client secret (arda volsync + backrest)" ;;
    ARDA_GITLAB_RUNNER_TOKEN) echo "GitLab CI runner auth token glrt-... (arda gitlab-runner)" ;;
    ARDA_OBSIDIAN_PASSWORD) echo "Obsidian LiveSync CouchDB admin password (arda obsidian/couchdb; update clients too)" ;;
    ARDA_HOMEASSISTANT_PASSWORD) echo "Home Assistant 'admin' owner password (requires in-pod hass auth change_password)" ;;
    ARDA_HOMEASSISTANT_LATITUDE) echo "Home Assistant latitude (updated by homeassistant-setup CronJob)" ;;
    ARDA_HOMEASSISTANT_LONGITUDE) echo "Home Assistant longitude (updated by homeassistant-setup CronJob)" ;;
    ARDA_PAPERLESS_SECRET_KEY) echo "Paperless Django SECRET_KEY (arda paperless; invalidates sessions)" ;;
    ARDA_PAPERLESS_ADMIN_PASSWORD) echo "Paperless 'paperless' superuser password (requires in-pod manage.py shell update)" ;;
    ARDA_PAPERLESS_SCANNER_PASSWORD) echo "Paperless Samba 'scanner' share password (arda paperless; update physical scanner)" ;;
    ARDA_PAPERLESS_MAIL_HOST|ARDA_PAPERLESS_MAIL_PORT|ARDA_PAPERLESS_MAIL_USER|ARDA_PAPERLESS_MAIL_PASSWORD|ARDA_PAPERLESS_MAIL_FOLDER)
      echo "Paperless IMAP mailbox config (applied by paperless-setup CronJob)" ;;
    ARDA_MEDIA_API_SECRET) echo "Media stack seed (7 app API keys + comicarr login + grimmory MariaDB password; requires DB & peer API sync)" ;;
    ARDA_COMICVINE_API_KEY) echo "ComicVine API key (arda media/comicarr)" ;;
    ARDA_LETTERBOXD_USER) echo "Letterboxd watchlist username (applied by media/wiring CronJob)" ;;
    ARDA_MULLVAD_PRIVATE_KEY|ARDA_MULLVAD_ADDRESSES|ARDA_MULLVAD_COUNTRY)
      echo "Mullvad WireGuard VPN config (arda media/qbittorrent gluetun sidecar)" ;;
    COMPOSE_PROFILE|DOWNLOAD_LINK|ASSETS_DIR|CLEAN_BOOT_FILES|CLEAN_OS_FILES|FORCE_REEXTRACT)
      echo "Bootstrap VM netboot/sdcard builder option (build-time only)" ;;
    VM_OS|VM_NAME|VM_CPUS|VM_MEMORY|VM_DISK|VM_REBUILD|VM_NETWORK)
      echo "Multipass bootstrap VM sizing/network setting (host-only)" ;;
    NFS_VERSION|NFS_EXPORT_0|NFS_LOG_LEVEL)
      echo "Bootstrap VM NFS server setting (host-only)" ;;
    BOOTSTRAP_IP_ADDRESS|PI_HOSTS|PI_USER)
      echo "Local bootstrap/SSH targeting setting (host-only)" ;;
    *) echo "Custom / uncatalogued variable" ;;
  esac
}

var_tier_e_warning() {
  case "$1" in
    ARDA_VOLSYNC_PASSWORD)
      echo "Encrypts EVERY restic backup repository (omni, lldap, all arda Longhorn PVCs). Blindly pushing a new value will break all backups! Use './rotate.sh restic-password' instead for zero-loss rotation." ;;
    AINUR_LLDAP_KEY_SEED)
      echo "Encrypts all stored user passwords in LLDAP's SQLite database (/data/users.db). Changing it invalidates EVERY user's password in LLDAP." ;;
    AINUR_LAB_CA_CRT|AINUR_LAB_CA_KEY)
      echo "Root CA trusted by ainur OIDC, cert-manager, all arda Talos nodes, and client browsers/phones. Overwriting without a dual-CA migration will break TLS cluster-wide." ;;
    *)
      echo "High-impact encryption or trust root." ;;
  esac
}

# Workloads on ainur that do NOT have Stakater Reloader and must be rolled manually.
# Output format: "namespace/kind/name" separated by spaces.
var_ainur_restarts() {
  case "$1" in
    AINUR_OIDC_CLIENT_SECRET)
      echo "argocd/deployment/argocd-server ainur-headlamp/deployment/headlamp ainur-sidero-omni/deployment/omni" ;;
    AINUR_NTFY_TOKEN|AINUR_DEADMAN_URL)
      echo "ainur-monitoring/statefulset/alertmanager-kps-alertmanager" ;;
    *)
      echo "" ;;
  esac
}

# Workloads on arda to rollout-restart when a key changes (arda has no Reloader).
var_arda_restarts() {
  case "$1" in
    AINUR_OIDC_CLIENT_SECRET)
      echo "oauth2-proxy/deployment/oauth2-proxy oauth2-proxy/deployment/oauth2-proxy-users paperless/deployment/paperless" ;;
    AINUR_SSO_SECRET)
      echo "oauth2-proxy/deployment/oauth2-proxy oauth2-proxy/deployment/oauth2-proxy-users transmute/deployment/transmute crowdsec/deployment/crowdsec-lapi crowdsec/daemonset/crowdsec-agent kube-system/deployment/traefik" ;;
    ARDA_CLOUDFLARE_API_TOKEN)
      echo "external-dns/deployment/external-dns external-dns/deployment/external-dns-tunnel ddns/deployment/ddns" ;;
    ARDA_CLOUDFLARE_TUNNEL_TOKEN)
      echo "cloudflared/deployment/cloudflared" ;;
    ARDA_UNIFI_API_KEY)
      echo "external-dns/deployment/external-dns-lan" ;;
    ARDA_MINECRAFT_WHITELIST|ARDA_MINECRAFT_BUILDERS)
      echo "minecraft/label:app.kubernetes.io/name=minecraft" ;;
    ARDA_DRAGONWILDS_OWNER_ID|ARDA_DRAGONWILDS_ADMIN_PASSWORD|ARDA_DRAGONWILDS_WORLD_PASSWORD)
      echo "dragonwilds/deployment/dragonwilds" ;;
    ARDA_BACKUP_ACCESS_KEY_ID|ARDA_BACKUP_SECRET_ACCESS_KEY|ARDA_BACKUP_ENDPOINT|ARDA_GDRIVE_TOKEN|ARDA_GDRIVE_CLIENT_ID|ARDA_GDRIVE_CLIENT_SECRET|ARDA_VOLSYNC_PASSWORD)
      echo "volsync-system/deployment/backrest" ;;
    ARDA_GITLAB_RUNNER_TOKEN)
      echo "gitlab-runner/deployment/gitlab-runner" ;;
    ARDA_OBSIDIAN_PASSWORD)
      echo "obsidian/deployment/couchdb" ;;
    ARDA_PAPERLESS_SECRET_KEY|ARDA_PAPERLESS_SCANNER_PASSWORD)
      echo "paperless/deployment/paperless" ;;
    ARDA_MEDIA_API_SECRET)
      echo "media/deployment/sonarr media/deployment/radarr media/deployment/prowlarr media/deployment/bazarr media/deployment/seerr media/deployment/chaptarr media/deployment/comicarr media/deployment/grimmory" ;;
    ARDA_COMICVINE_API_KEY)
      echo "media/deployment/comicarr" ;;
    ARDA_MULLVAD_PRIVATE_KEY|ARDA_MULLVAD_ADDRESSES|ARDA_MULLVAD_COUNTRY)
      echo "media/deployment/qbittorrent" ;;
    *)
      echo "" ;;
  esac
}

# --- SSH Transport to Pis (matches bootstrap/netboot/rebootstrap.sh) -------
# Resolves control-plane Pi host (valar-50) and SSH user from .env / env vars.
resolve_pi_targets() {
  local raw_hosts
  raw_hosts="${PI_HOSTS:-$(env_get PI_HOSTS)}"
  PI_HOSTS_LIST="${raw_hosts:-192.168.1.50 192.168.1.51 192.168.1.52}"
  PI_USER_RESOLVED="${PI_USER:-$(env_get PI_USER)}"
  PI_USER_RESOLVED="${PI_USER_RESOLVED:-ubuntu}"
  # shellcheck disable=SC2034
  AINUR_CP_HOST="${AINUR_CONTROL_PLANE:-$(printf '%s' "$PI_HOSTS_LIST" | awk '{print $1}')}"
}

detect_ssh_driver() {
  if [ -n "${ROTATE_SSH_DRIVER:-}" ]; then
    echo "$ROTATE_SSH_DRIVER"
    return
  fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v docker >/dev/null 2>&1; then
        echo "docker"
      else
        echo "native"
      fi
      ;;
    *)
      if command -v ssh >/dev/null 2>&1; then
        echo "native"
      else
        echo "docker"
      fi
      ;;
  esac
}

# Run a shell script provided on stdin on a Pi host via SSH as root (sudo sh).
# Usage: ssh_pi_sudo <host> <push_key_b64> <script_file>
# Never puts the private key on the remote host or in process arguments.
ssh_pi_sudo() {
  local host="$1" key_b64="$2" script_file="$3"
  local driver
  driver="$(detect_ssh_driver)"
  resolve_pi_targets

  if [ -z "$key_b64" ]; then
    err "AINUR_PUSH_KEY is empty; cannot SSH to $host."
    return 1
  fi

  if [ "$driver" = "docker" ]; then
    local script_b64
    script_b64="$(base64 < "$script_file" | tr -d '\r\n')"
    MSYS_NO_PATHCONV=1 docker run --rm -i \
      -e PUSH_KEY="$key_b64" \
      -e PI_USER="$PI_USER_RESOLVED" \
      -e PI_HOST="$host" \
      -e REMOTE_SCRIPT_B64="$script_b64" \
      alpine:3.20 sh -c '
        set -eu
        apk add -q --no-cache openssh-client >/dev/null
        umask 077
        printf "%s\n" "$PUSH_KEY" | base64 -d > /tmp/k
        chmod 600 /tmp/k
        printf "%s\n" "$REMOTE_SCRIPT_B64" | base64 -d | \
          ssh -i /tmp/k -o BatchMode=yes -o IdentitiesOnly=yes \
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -o LogLevel=ERROR \
              "${PI_USER}@${PI_HOST}" "sudo sh -s"
      '
  else
    local key_tmp
    key_tmp="$(mktemp)"
    chmod 600 "$key_tmp"
    printf '%s\n' "$key_b64" | base64 -d > "$key_tmp"
    local rc=0
    ssh -i "$key_tmp" -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR \
        "${PI_USER_RESOLVED}@${host}" "sudo sh -s" < "$script_file" || rc=$?
    rm -f "$key_tmp"
    return "$rc"
  fi
}
