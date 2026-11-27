#!/usr/bin/env bash
# Forces values from local bootstrap/netboot/.env onto the running ainur & arda
# clusters without requiring the bootstrap VM.
#
# - Diffs local .env against live cluster Secrets (by SHA-256 prefix only;
#   raw secrets are never printed).
# - Groups changes by Tier (B, C, D, E):
#     * Tiers B, C, D: one-time confirmation per tier
#     * Tier E (highest): individual confirmation per variable (type exact name)
# - Merges ONLY approved keys onto valar-50, runs ainur-secrets & arda-secrets,
#   triggers arda-bootstrap when needed, runs Tier C stateful DB/API reconcilers,
#   rolls affected workloads, and verifies cluster health.
#
# Usage:
#   ./sync-env.sh [--dry-run] [--only KEY1,KEY2] [--all-restarts] [--no-stateful] [--env FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rotate-common.sh
. "$SCRIPT_DIR/lib/rotate-common.sh"
# shellcheck source=lib/reconcile-stateful.sh
. "$SCRIPT_DIR/lib/reconcile-stateful.sh"

DRY_RUN=0
ONLY_KEYS=""
ALL_RESTARTS=0
NO_STATEFUL=0
FORCE_CHANGED=""
PRECONFIRMED_TIERS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --dry-run            Inspect live cluster diff and print planned actions without modifying anything
  --only KEY1,KEY2     Restrict sync to the comma-separated list of keys
  --all-restarts       Restart affected workloads for --only / all present keys even if hashes match
  --no-stateful        Skip Tier C in-app DB/API reconcilers
  --env PATH           Path to .env file (default: $ENV_FILE)
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --only) ONLY_KEYS="${2:?missing value for --only}"; shift ;;
    --all-restarts) ALL_RESTARTS=1 ;;
    --no-stateful) NO_STATEFUL=1 ;;
    --env) ENV_FILE="${2:?missing value for --env}"; shift ;;
    --force-changed) FORCE_CHANGED="${2:?missing value for --force-changed}"; shift ;;
    --preconfirmed-tiers) PRECONFIRMED_TIERS="${2:?missing value for --preconfirmed-tiers}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

require_env_file
resolve_pi_targets

PUSH_KEY="$(env_get AINUR_PUSH_KEY)"
if [ -z "$PUSH_KEY" ]; then
  err "AINUR_PUSH_KEY is unset in $ENV_FILE — needed to SSH into $AINUR_CP_HOST."
  exit 1
fi

banner "project-iluvatar: Live .env Sync" \
  "Source: $ENV_FILE | Control plane: ${PI_USER_RESOLVED}@${AINUR_CP_HOST} | Mode: $([ "$DRY_RUN" = 1 ] && echo 'DRY-RUN' || echo 'LIVE')"

# --- Step 1: Collect live Secret hashes from valar-50 (read-only) ----------
step "Step 1/6: Connecting to ${AINUR_CP_HOST} to read live Secret fingerprints (read-only)..."
info "Transport driver: $(detect_ssh_driver) (set ROTATE_SSH_DRIVER=native|docker to override)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/probe.sh" <<'EOF'
set -eu
python3 - <<'PY'
import base64, hashlib, json, os, subprocess

def secret_hashes(ns, name):
    try:
        out = subprocess.check_output(
            ["k3s", "kubectl", "-n", ns, "get", "secret", name, "-o", "json"],
            stderr=subprocess.DEVNULL, text=True
        )
    except Exception:
        return {}
    data = json.loads(out).get("data") or {}
    res = {}
    for k, v in data.items():
        raw = base64.b64decode(v).decode("utf-8", errors="replace").rstrip("\r\n")
        res[k] = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:10] if raw else "(empty)"
    return res

live = {}
# Merge ainur-netboot (has push key + k3s tokens) then ainur-dex (app secrets) then arda-secrets
live.update(secret_hashes("ainur-netboot", "ainur-secrets"))
live.update(secret_hashes("ainur-dex", "ainur-secrets"))
live.update(secret_hashes("ainur-sidero-omni", "arda-secrets"))

# Lab CA files on disk (ainur-secrets.sh strips AINUR_LAB_CA_* from Secrets)
for var, path in [("AINUR_LAB_CA_CRT", "/etc/rancher/k3s/oidc/lab-ca.crt"),
                  ("AINUR_LAB_CA_KEY", "/etc/k3s-certs/lab-ca.key")]:
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        b64 = base64.b64encode(open(path, "rb").read()).decode("ascii")
        live[var] = hashlib.sha256(b64.encode("ascii")).hexdigest()[:10]

for k in sorted(live):
    print(f"{k}={live[k]}")
PY
EOF

LIVE_HASHES_FILE="$TMP_DIR/live-hashes.txt"
if ! ssh_pi_sudo "$AINUR_CP_HOST" "$PUSH_KEY" "$TMP_DIR/probe.sh" > "$LIVE_HASHES_FILE"; then
  err "Failed to query live Secret hashes on $AINUR_CP_HOST."
  exit 1
fi
ok "Fetched $(wc -l < "$LIVE_HASHES_FILE" | tr -d ' ') live Secret key fingerprints from ainur."

live_hash_of() {
  local k="$1" v
  v="$(grep -E "^${k}=" "$LIVE_HASHES_FILE" | head -n1 | cut -d= -f2- || true)"
  printf '%s' "${v:-(missing)}"
}

# --- Step 2: Diff local .env against live hashes, grouped by Tier ----------
step "Step 2/6: Comparing local .env against live cluster state..."

declare -a TIER_B_KEYS=() TIER_C_KEYS=() TIER_D_KEYS=() TIER_E_KEYS=()
declare -A LOCAL_HASHES=() LIVE_HASHES=() KEY_STATUS=()

key_in_csv() {
  local needle="$1" csv="$2"
  [ -z "$csv" ] && return 0
  case ",$csv," in *,"$needle",*) return 0 ;; *) return 1 ;; esac
}

ALL_LOCAL_KEYS="$(env_list_cluster_keys "$ENV_FILE")"
UNCHANGED_COUNT=0
SKIPPED_EMPTY=0

for key in $ALL_LOCAL_KEYS; do
  key_in_csv "$key" "$ONLY_KEYS" || continue
  val="$(env_get "$key")"
  lhash="$(short_hash "$val")"
  rhash="$(live_hash_of "$key")"
  LOCAL_HASHES["$key"]="$lhash"
  LIVE_HASHES["$key"]="$rhash"

  # Skip unset keys in .env that are also absent on cluster
  if [ "$lhash" = "(empty)" ] && [ "$rhash" = "(missing)" ]; then
    SKIPPED_EMPTY=$((SKIPPED_EMPTY + 1))
    continue
  fi

  force_this=0
  if [ "$ALL_RESTARTS" = 1 ]; then force_this=1; fi
  if [ -n "$FORCE_CHANGED" ] && key_in_csv "$key" "$FORCE_CHANGED"; then force_this=1; fi

  if [ "$lhash" = "$rhash" ] && [ "$force_this" = 0 ]; then
    UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
    continue
  fi

  if [ "$rhash" = "(missing)" ]; then
    KEY_STATUS["$key"]="ADDED"
  elif [ "$lhash" = "$rhash" ]; then
    KEY_STATUS["$key"]="FORCED"
  else
    KEY_STATUS["$key"]="CHANGED"
  fi

  tier="$(var_tier "$key")"
  case "$tier" in
    B) TIER_B_KEYS+=("$key") ;;
    C) TIER_C_KEYS+=("$key") ;;
    D) TIER_D_KEYS+=("$key") ;;
    E) TIER_E_KEYS+=("$key") ;;
  esac
done

TOTAL_DIFF=$(( ${#TIER_B_KEYS[@]} + ${#TIER_C_KEYS[@]} + ${#TIER_D_KEYS[@]} + ${#TIER_E_KEYS[@]} ))
info "Summary: $TOTAL_DIFF key(s) to sync | $UNCHANGED_COUNT unchanged | $SKIPPED_EMPTY empty/unset skipped."

if [ "$TOTAL_DIFF" -eq 0 ]; then
  ok "Live cluster Secrets already match local .env! Nothing to push."
  info "Tip: pass --all-restarts (optionally with --only KEY) to force restarts anyway."
  exit 0
fi

print_tier_table() {
  local tier="$1" title="$2"
  shift 2
  local keys=("$@")
  [ "${#keys[@]}" -gt 0 ] || return 0
  section "Tier $tier — $title (${#keys[@]} key(s))"
  for k in "${keys[@]}"; do
    printf '  %s%-32s%s [%-7s] live:%-10s -> local:%-10s (%s)\n' \
      "$C_BOLD" "$k" "$C_RESET" "${KEY_STATUS[$k]}" "${LIVE_HASHES[$k]}" "${LOCAL_HASHES[$k]}" "$(var_cluster "$k")"
    detail "$(var_summary "$k")"
    local ar ra
    ar="$(var_ainur_restarts "$k")"
    ra="$(var_arda_restarts "$k")"
    if [ -n "$ar" ]; then detail "ainur manual restarts: $ar"; fi
    if [ -n "$ra" ]; then detail "arda restarts:         $ra"; fi
  done
}

print_tier_table "B" "Standard Secret Sync + Rollout Restarts" "${TIER_B_KEYS[@]}"
print_tier_table "C" "Stateful In-App DB / API Reconciliation" "${TIER_C_KEYS[@]}"
print_tier_table "D" "Host / Cluster-Level Pi Credentials" "${TIER_D_KEYS[@]}"
print_tier_table "E" "HIGHEST TIER — Encryption & Trust Roots" "${TIER_E_KEYS[@]}"

if [ "$DRY_RUN" = 1 ]; then
  banner "Dry-Run Complete" "No changes were pushed to ainur or arda."
  exit 0
fi

# --- Step 3: Tier-based confirmations (1 per Tier B/C/D; per-entry Tier E) -
step "Step 3/6: Requesting confirmations by tier..."

declare -a APPROVED_KEYS=()

tier_preconfirmed() {
  [ -n "$PRECONFIRMED_TIERS" ] && case ",$PRECONFIRMED_TIERS," in *,"$1",*) return 0 ;; esac
  return 1
}

if [ "${#TIER_B_KEYS[@]}" -gt 0 ]; then
  if tier_preconfirmed "B"; then
    ok "Tier B already confirmed by rotate.sh — proceeding (${#TIER_B_KEYS[@]} key(s))."
    APPROVED_KEYS+=("${TIER_B_KEYS[@]}")
  elif confirm_tier "B" "Standard Secret Sync + Rollout Restarts" "${#TIER_B_KEYS[@]}"; then
    APPROVED_KEYS+=("${TIER_B_KEYS[@]}")
  fi
fi

if [ "${#TIER_C_KEYS[@]}" -gt 0 ]; then
  info "Tier C will also run live DB/API updates inside running pods (LLDAP / MariaDB / Paperless / Home Assistant / media peers)."
  if tier_preconfirmed "C"; then
    ok "Tier C already confirmed by rotate.sh — proceeding (${#TIER_C_KEYS[@]} key(s))."
    APPROVED_KEYS+=("${TIER_C_KEYS[@]}")
  elif confirm_tier "C" "Stateful In-App DB / API Reconciliation" "${#TIER_C_KEYS[@]}"; then
    APPROVED_KEYS+=("${TIER_C_KEYS[@]}")
  fi
fi

if [ "${#TIER_D_KEYS[@]}" -gt 0 ]; then
  warn "Tier D keys control Pi SSH access and k3s node joining."
  info "Note: sync-env.sh updates Kubernetes Secrets; for zero-downtime host cutover use './rotate.sh push-key' or './rotate.sh k3s-tokens'."
  if tier_preconfirmed "D"; then
    ok "Tier D already confirmed by rotate.sh — proceeding (${#TIER_D_KEYS[@]} key(s))."
    APPROVED_KEYS+=("${TIER_D_KEYS[@]}")
  elif confirm_tier "D" "Host / Cluster-Level Pi Credentials (Secret sync)" "${#TIER_D_KEYS[@]}"; then
    APPROVED_KEYS+=("${TIER_D_KEYS[@]}")
  fi
fi

if [ "${#TIER_E_KEYS[@]}" -gt 0 ]; then
  warn "Tier E contains encryption/trust-root keys. Each entry requires individual confirmation."
  for k in "${TIER_E_KEYS[@]}"; do
    if confirm_tier_e_entry "$k" "$(var_tier_e_warning "$k")"; then
      APPROVED_KEYS+=("$k")
    fi
  done
fi

if [ "${#APPROVED_KEYS[@]}" -eq 0 ]; then
  warn "No changes were approved. Exiting with zero modifications."
  exit 0
fi

ok "Approved ${#APPROVED_KEYS[@]} key(s): ${APPROVED_KEYS[*]}"

# --- Step 4: Build remote push + reconcile + restart script ----------------
step "Step 4/6: Preparing remote execution bundle for ${AINUR_CP_HOST}..."

# Encode approved key=value pairs in two files (ainur vs arda) so unapproved
# keys stay untouched on valar-50.
AINUR_PATCH_FILE="$TMP_DIR/ainur.patch"
ARDA_PATCH_FILE="$TMP_DIR/arda.patch"
: > "$AINUR_PATCH_FILE"
: > "$ARDA_PATCH_FILE"

NEED_AINUR_SVC=0
NEED_ARDA_SVC=0
NEED_ARDA_BOOTSTRAP=0
NEED_LAB_CA=0
RECON_LLDAP_DEX=0
RECON_PAPERLESS_ADMIN=0
RECON_HA_OWNER=0
RECON_MEDIA=0
RECON_TRANSMUTE=0

declare -A AINUR_RESTART_SET=() ARDA_RESTART_SET=()

for k in "${APPROVED_KEYS[@]}"; do
  val="$(env_get "$k")"
  case "$k" in
    AINUR_*)
      printf '%s=%s\n' "$k" "$val" >> "$AINUR_PATCH_FILE"
      NEED_AINUR_SVC=1
      ;;
    ARDA_*)
      printf '%s=%s\n' "$k" "$val" >> "$ARDA_PATCH_FILE"
      NEED_ARDA_SVC=1
      ;;
  esac
  if var_needs_arda_bootstrap "$k"; then NEED_ARDA_BOOTSTRAP=1; fi
  case "$k" in
    AINUR_LAB_CA_CRT|AINUR_LAB_CA_KEY) NEED_LAB_CA=1 ;;
    AINUR_LLDAP_DEX_PASSWORD) RECON_LLDAP_DEX=1 ;;
    ARDA_PAPERLESS_ADMIN_PASSWORD) RECON_PAPERLESS_ADMIN=1 ;;
    ARDA_HOMEASSISTANT_PASSWORD) RECON_HA_OWNER=1 ;;
    ARDA_MEDIA_API_SECRET) RECON_MEDIA=1 ;;
    AINUR_SSO_SECRET) RECON_TRANSMUTE=1 ;;
  esac
  for t in $(var_ainur_restarts "$k"); do AINUR_RESTART_SET["$t"]=1; done
  for t in $(var_arda_restarts "$k"); do ARDA_RESTART_SET["$t"]=1; done
done

AINUR_PATCH_B64="$(base64 < "$AINUR_PATCH_FILE" | tr -d '\r\n')"
ARDA_PATCH_B64="$(base64 < "$ARDA_PATCH_FILE" | tr -d '\r\n')"

REMOTE_SCRIPT="$TMP_DIR/apply.sh"
cat > "$REMOTE_SCRIPT" <<EOF
set -eu
umask 077
mkdir -p /run/ainur
chmod 700 /run/ainur

WORK="\$(mktemp -d)"
ARDA_KC="\$WORK/arda-kubeconfig"
trap 'rm -rf "\$WORK"' EXIT

merge_env() {
  target="\$1" ns="\$2" secret="\$3" patch_b64="\$4"
  # Seed target from live Kubernetes Secret if /run/ainur/*.env is absent (e.g. after reboot)
  if [ ! -s "\$target" ]; then
    echo "[ainur] Seeding \$target from live Secret \$ns/\$secret..."
    k3s kubectl -n "\$ns" get secret "\$secret" -o json 2>/dev/null | python3 -c '
import base64, json, sys
raw = sys.stdin.read().strip()
if not raw: sys.exit(0)
data = json.loads(raw).get("data") or {}
for k in sorted(data):
    v = base64.b64decode(data[k]).decode("utf-8", errors="replace").rstrip("\r\n")
    print(f"{k}={v}")
' > "\$target" || : > "\$target"
  fi
  printf '%s' "\$patch_b64" | base64 -d > "\$WORK/patch.env"
  python3 - "\$target" "\$WORK/patch.env" <<'PY'
import sys
target, patch = sys.argv[1], sys.argv[2]
kv = {}
order = []
def load(p):
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        k, v = line.split("=", 1)
        if k not in kv:
            order.append(k)
        kv[k] = v
load(target)
load(patch)
with open(target + ".new", "w", encoding="utf-8") as f:
    for k in order:
        f.write(f"{k}={kv[k]}\n")
PY
  mv "\$target.new" "\$target"
  chmod 600 "\$target"
}

if [ "$NEED_AINUR_SVC" = 1 ]; then
  echo "[ainur] ==> Merging approved AINUR_* keys into /run/ainur/ainur.env..."
  merge_env /run/ainur/ainur.env ainur-dex ainur-secrets "$AINUR_PATCH_B64"
  echo "[ainur] ==> Running ainur-secrets.service (updates ainur-secrets across namespaces & headlamp-oidc)..."
  systemctl start ainur-secrets.service
  echo "[ainur] [OK] ainur-secrets.service applied"
fi

if [ "$NEED_ARDA_SVC" = 1 ]; then
  echo "[ainur] ==> Merging approved ARDA_* keys into /run/ainur/arda.env..."
  merge_env /run/ainur/arda.env ainur-sidero-omni arda-secrets "$ARDA_PATCH_B64"
  echo "[ainur] ==> Running arda-secrets.service (updates ainur-sidero-omni/arda-secrets)..."
  systemctl start arda-secrets.service
  echo "[ainur] [OK] arda-secrets.service applied"
fi

# Keep /run/ainur/env.sha256 consistent with push-secrets.sh
if [ -f /run/ainur/ainur.env ] || [ -f /run/ainur/arda.env ]; then
  { cat /run/ainur/ainur.env 2>/dev/null || true; echo; cat /run/ainur/arda.env 2>/dev/null || true; echo; } \
    | sha256sum | cut -d' ' -f1 > /run/ainur/env.sha256
fi

if [ "$NEED_LAB_CA" = 1 ]; then
  echo "[ainur] ==> Applying approved Lab CA update via tls-bootstrap.service..."
  systemctl restart tls-bootstrap.service
  echo "[ainur] [OK] tls-bootstrap.service completed"
fi

# Build temporary arda kubeconfig from ainur's argocd/cluster-arda Secret
if k3s kubectl -n argocd get secret cluster-arda >/dev/null 2>&1; then
  k3s kubectl -n argocd get secret cluster-arda -o json | python3 - "\$ARDA_KC" <<'PY'
import base64, json, sys
sec = json.load(sys.stdin)
data = sec.get("data") or {}
server = base64.b64decode(data["server"]).decode().strip()
cfg = json.loads(base64.b64decode(data["config"]).decode())
ca = cfg.get("tlsClientConfig", {}).get("caData", "")
token = cfg["bearerToken"]
kc = f"""apiVersion: v1
kind: Config
clusters:
- name: arda
  cluster:
    server: {server}
    certificate-authority-data: {ca}
users:
- name: argocd-manager
  user:
    token: {token}
contexts:
- name: arda
  context:
    cluster: arda
    user: argocd-manager
current-context: arda
"""
with open(sys.argv[1], "w") as f:
    f.write(kc)
PY
  chmod 600 "\$ARDA_KC"
  echo "[arda] [OK] Constructed temporary arda kubeconfig from argocd/cluster-arda"
else
  echo "[arda] WARN: argocd/cluster-arda Secret not found; arda actions will be skipped"
  ARDA_KC=""
fi
EOF

# Trigger arda-bootstrap Job if any arda-consumed secret changed
if [ "$NEED_ARDA_BOOTSTRAP" = 1 ]; then
  cat >> "$REMOTE_SCRIPT" <<'EOF'
echo "[ainur] ==> Triggering arda-bootstrap Job to push Secrets to arda..."
if k3s kubectl -n ainur-sidero-omni get job arda-bootstrap >/dev/null 2>&1; then
  # Clone the existing Job spec (stripping generated controller fields) into a fresh one-shot run
  JOB_NAME="arda-bootstrap-sync-$(date +%s)"
  k3s kubectl -n ainur-sidero-omni get job arda-bootstrap -o json | python3 - "$JOB_NAME" <<'PY' | k3s kubectl apply -f -
import json, sys
j = json.load(sys.stdin)
j["metadata"] = {"name": sys.argv[1], "namespace": "ainur-sidero-omni"}
j.pop("status", None)
spec = j["spec"]
spec.pop("selector", None)
spec["ttlSecondsAfterFinished"] = 600
tmeta = spec.get("template", {}).get("metadata", {})
tmeta.pop("creationTimestamp", None)
labels = tmeta.get("labels") or {}
for k in list(labels):
    if k.startswith("batch.kubernetes.io/") or k in ("controller-uid", "job-name"):
        labels.pop(k, None)
tmeta["labels"] = labels
print(json.dumps(j))
PY
  echo "[ainur]   Waiting for Job $JOB_NAME to complete (up to 5m)..."
  k3s kubectl -n ainur-sidero-omni wait --for=condition=complete "job/$JOB_NAME" --timeout=300s
  k3s kubectl -n ainur-sidero-omni logs "job/$JOB_NAME" | tail -n 15
  echo "[ainur] [OK] $JOB_NAME completed — arda Secrets updated"
else
  echo "[ainur]   arda-bootstrap Job not currently present; asking Argo CD (ainur/sidero-omni) to hard-refresh and recreate it..."
  k3s kubectl -n ainur annotate application sidero-omni argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    k3s kubectl -n ainur-sidero-omni get job arda-bootstrap >/dev/null 2>&1 && break
    sleep 3
  done
  if k3s kubectl -n ainur-sidero-omni get job arda-bootstrap >/dev/null 2>&1; then
    k3s kubectl -n ainur-sidero-omni wait --for=condition=complete job/arda-bootstrap --timeout=300s
    k3s kubectl -n ainur-sidero-omni logs job/arda-bootstrap | tail -n 15
    echo "[ainur] [OK] arda-bootstrap completed"
  else
    echo "[ainur] WARN: arda-bootstrap Job did not appear within 90s; check Argo CD app ainur/sidero-omni"
  fi
fi
EOF
fi

# Pre-restart Tier C reconcilers (LLDAP dex user, Grimmory MariaDB)
if [ "$NO_STATEFUL" = 0 ]; then
  if [ "$RECON_LLDAP_DEX" = 1 ]; then
    emit_reconcile_lldap_dex >> "$REMOTE_SCRIPT"
  fi
  if [ "$RECON_MEDIA" = 1 ]; then
    echo 'if [ -n "$ARDA_KC" ]; then' >> "$REMOTE_SCRIPT"
    emit_reconcile_grimmory_mariadb >> "$REMOTE_SCRIPT"
    echo 'fi' >> "$REMOTE_SCRIPT"
  fi
fi

# Targeted rollout restarts on ainur (non-Reloader deployments)
if [ "${#AINUR_RESTART_SET[@]}" -gt 0 ]; then
  echo 'echo "[ainur] ==> Restarting non-Reloader workloads on ainur..."' >> "$REMOTE_SCRIPT"
  for target in "${!AINUR_RESTART_SET[@]}"; do
    ns="${target%%/*}"
    rest="${target#*/}"
    cat >> "$REMOTE_SCRIPT" <<EOF
if k3s kubectl -n "$ns" get "$rest" >/dev/null 2>&1; then
  echo "[ainur]   rollout restart $ns/$rest"
  k3s kubectl -n "$ns" rollout restart "$rest"
  k3s kubectl -n "$ns" rollout status "$rest" --timeout=180s
else
  echo "[ainur]   skip $ns/$rest (not deployed)"
fi
EOF
  done
fi

# Targeted rollout restarts on arda
if [ "${#ARDA_RESTART_SET[@]}" -gt 0 ]; then
  echo 'if [ -n "$ARDA_KC" ]; then' >> "$REMOTE_SCRIPT"
  echo '  echo "[arda] ==> Restarting affected workloads on arda..."' >> "$REMOTE_SCRIPT"
  for target in "${!ARDA_RESTART_SET[@]}"; do
    ns="${target%%/*}"
    rest="${target#*/}"
    case "$rest" in
      label:*)
        sel="${rest#label:}"
        cat >> "$REMOTE_SCRIPT" <<EOF
  echo "[arda]   restarting deployments/statefulsets in $ns matching $sel"
  for obj in \$(kubectl --kubeconfig "\$ARDA_KC" -n "$ns" get deploy,sts -l "$sel" -o name 2>/dev/null || true); do
    kubectl --kubeconfig "\$ARDA_KC" -n "$ns" rollout restart "\$obj"
    kubectl --kubeconfig "\$ARDA_KC" -n "$ns" rollout status "\$obj" --timeout=240s || true
  done
EOF
        ;;
      *)
        cat >> "$REMOTE_SCRIPT" <<EOF
  if kubectl --kubeconfig "\$ARDA_KC" -n "$ns" get "$rest" >/dev/null 2>&1; then
    echo "[arda]   rollout restart $ns/$rest"
    kubectl --kubeconfig "\$ARDA_KC" -n "$ns" rollout restart "$rest"
    kubectl --kubeconfig "\$ARDA_KC" -n "$ns" rollout status "$rest" --timeout=180s || true
  else
    echo "[arda]   skip $ns/$rest (not deployed)"
  fi
EOF
        ;;
    esac
  done
  echo 'fi' >> "$REMOTE_SCRIPT"
fi

# Post-restart Tier C reconcilers (Paperless superuser, HA owner, Media peer API keys, Transmute admin)
if [ "$NO_STATEFUL" = 0 ]; then
  if [ "$RECON_PAPERLESS_ADMIN" = 1 ] || [ "$RECON_HA_OWNER" = 1 ] || [ "$RECON_MEDIA" = 1 ] || [ "$RECON_TRANSMUTE" = 1 ]; then
    echo 'if [ -n "$ARDA_KC" ]; then' >> "$REMOTE_SCRIPT"
    [ "$RECON_PAPERLESS_ADMIN" = 1 ] && emit_reconcile_paperless_admin >> "$REMOTE_SCRIPT"
    [ "$RECON_HA_OWNER" = 1 ] && emit_reconcile_homeassistant_owner >> "$REMOTE_SCRIPT"
    [ "$RECON_MEDIA" = 1 ] && emit_reconcile_media_peer_keys >> "$REMOTE_SCRIPT"
    [ "$RECON_TRANSMUTE" = 1 ] && emit_reconcile_transmute_admin >> "$REMOTE_SCRIPT"
    echo 'fi' >> "$REMOTE_SCRIPT"
  fi
fi

# Trigger Paperless mail CronJob if mail keys changed
for k in "${APPROVED_KEYS[@]}"; do
  case "$k" in
    ARDA_PAPERLESS_MAIL_*)
      cat >> "$REMOTE_SCRIPT" <<'EOF'
if [ -n "$ARDA_KC" ] && kubectl --kubeconfig "$ARDA_KC" -n paperless get cronjob paperless-setup >/dev/null 2>&1; then
  echo "[arda] ==> Triggering paperless-setup CronJob to apply mailbox settings..."
  JOB="paperless-setup-sync-$(date +%s)"
  kubectl --kubeconfig "$ARDA_KC" -n paperless create job --from=cronjob/paperless-setup "$JOB"
  kubectl --kubeconfig "$ARDA_KC" -n paperless wait --for=condition=complete "job/$JOB" --timeout=120s || true
fi
EOF
      break
      ;;
  esac
done

# Post-sync health check
cat >> "$REMOTE_SCRIPT" <<'EOF'
echo "[verify] ==> Running post-sync health checks..."
for item in "ainur-dex/deploy/lldap" "ainur-dex/deploy/dex" "argocd/deploy/argocd-server" "ainur-monitoring/deploy/ntfy"; do
  ns="${item%%/*}"; obj="${item#*/}"
  if k3s kubectl -n "$ns" get "$obj" >/dev/null 2>&1; then
    k3s kubectl -n "$ns" rollout status "$obj" --timeout=90s >/dev/null && echo "[verify] [OK] ainur $item ready" || echo "[verify] WARN: ainur $item not ready yet"
  fi
done
if [ -n "$ARDA_KC" ]; then
  unready="$(kubectl --kubeconfig "$ARDA_KC" get deploy -A --no-headers 2>/dev/null | awk '$3 != $4 {print $1 "/" $2 " (" $3 ")"}' || true)"
  if [ -z "$unready" ]; then
    echo "[verify] [OK] All Deployments on arda report desired replicas ready"
  else
    echo "[verify] Note — arda Deployments still settling:"
    printf '%s\n' "$unready" | sed 's/^/  - /'
  fi
fi
EOF

# --- Step 5: Execute remotely on valar-50 ----------------------------------
step "Step 5/6: Pushing approved keys and executing live sync on ${AINUR_CP_HOST}..."
ssh_pi_sudo "$AINUR_CP_HOST" "$PUSH_KEY" "$REMOTE_SCRIPT"

# --- Step 6: Done ----------------------------------------------------------
step "Step 6/6: Live sync complete!"
ok "Successfully forced ${#APPROVED_KEYS[@]} approved key(s) onto running cluster(s)."
