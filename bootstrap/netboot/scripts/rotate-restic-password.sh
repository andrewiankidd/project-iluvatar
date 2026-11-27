#!/usr/bin/env bash
# Tier E (Highest Tier) zero-loss rotation for ARDA_VOLSYNC_PASSWORD across
# EVERY restic backup repository:
#   - ainur R2 repos:  arda-backups/omni, arda-backups/lldap (when ARDA_BACKUP_* set)
#   - arda VolSync repos: every repo under arda-backups/volsync/<ns>/<pvc> (Drive or R2)
#
# Safe 4-phase key swap (no re-upload, zero backup loss):
#   1. Adds the NEW password as a second key to every discovered restic repo
#      (`restic key add`).
#   2. Verifies every repo opens cleanly with the NEW password.
#   3. Backs up .env, writes new ARDA_VOLSYNC_PASSWORD, and syncs Secrets to
#      ainur + arda (Kyverno propagates to every <pvc>-volsync Secret) + restarts backrest.
#   4. Removes the OLD key ID from every restic repo (`restic key remove`).
#
# Usage:
#   ./rotate-restic-password.sh [--dry-run] [--skip-confirm] [--env FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rotate-common.sh
. "$SCRIPT_DIR/lib/rotate-common.sh"

DRY_RUN=0
SKIP_CONFIRM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-confirm) SKIP_CONFIRM=1 ;;
    --env) ENV_FILE="${2:?missing value for --env}"; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--dry-run] [--skip-confirm] [--env PATH]"
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

require_env_file
resolve_pi_targets

PUSH_KEY="$(env_get AINUR_PUSH_KEY)"
OLD_PW="$(env_get ARDA_VOLSYNC_PASSWORD)"
if [ -z "$PUSH_KEY" ] || [ -z "$OLD_PW" ]; then
  err "AINUR_PUSH_KEY and current ARDA_VOLSYNC_PASSWORD must be set in $ENV_FILE."
  exit 1
fi

banner "Tier E (Highest Tier): Zero-Loss Restic Password Rotation" \
  "Variable: ARDA_VOLSYNC_PASSWORD | Runs on: $AINUR_CP_HOST (with rclone + restic container)"

info "Current ARDA_VOLSYNC_PASSWORD fingerprint: $(short_hash "$OLD_PW")"
info "Safe 4-step workflow:"
detail "1. Discover all restic repos (R2: omni, lldap, volsync/*; Google Drive: arda-backups/volsync/*)"
detail "2. Add a fresh 32-char random password to EVERY repo ('restic key add') and verify it opens"
detail "3. Backup .env, save new ARDA_VOLSYNC_PASSWORD, sync ainur + arda Secrets (Kyverno updates all PVCs)"
detail "4. Remove the OLD key from every repo ONLY after step 3 succeeds"

if [ "$DRY_RUN" = 1 ]; then
  ok "Dry-run complete — no restic keys or .env modified."
  exit 0
fi

if [ "$SKIP_CONFIRM" = 0 ]; then
  confirm_tier_e_entry "ARDA_VOLSYNC_PASSWORD" \
    "Rotates the restic encryption key on ALL backup repositories (omni, lldap, and every arda VolSync PVC)." \
    || exit 0
fi

NEW_PW="$(rand_alnum 32)"
info "Generated new 32-char password (fingerprint: $(short_hash "$NEW_PW"))"
warn "Keep a copy of the new ARDA_VOLSYNC_PASSWORD from .env in your password manager after rotation!"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Helper to emit a remote script running a temporary alpine/restic+rclone pod on ainur
# that reads credentials from ainur-sidero-omni/arda-secrets.
emit_restic_op() {
  local mode="$1" old_b64="$2" new_b64="$3"
  printf 'MODE=%q\nOLD_B64=%q\nNEW_B64=%q\n' "$mode" "$old_b64" "$new_b64"
  cat <<'EOF'
set -eu
POD="restic-rotate-$(date +%s)"
cleanup() { k3s kubectl -n ainur-sidero-omni delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

cat <<POD_YAML | k3s kubectl -n ainur-sidero-omni apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ainur-sidero-omni
spec:
  restartPolicy: Never
  containers:
    - name: restic
      image: alpine:3.22
      command: ["sh", "-c", "apk add -q --no-cache restic rclone jq >/dev/null && sleep 600"]
      envFrom:
        - secretRef:
            name: arda-secrets
POD_YAML

echo "[restic] Waiting for helper pod $POD to be ready..."
k3s kubectl -n ainur-sidero-omni wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null

printf '%s\n%s\n' "$OLD_B64" "$NEW_B64" | \
  k3s kubectl -n ainur-sidero-omni exec -i "pod/$POD" -- sh -s "$MODE" <<'INNER'
set -eu
MODE="$1"
IFS= read -r OLD_B64
IFS= read -r NEW_B64
OLD_PW="$(printf '%s' "$OLD_B64" | base64 -d)"
NEW_PW="$(printf '%s' "$NEW_B64" | base64 -d)"

umask 077
printf '%s\n' "$OLD_PW" > /tmp/old.pw
printf '%s\n' "$NEW_PW" > /tmp/new.pw

# Configure R2 and/or Google Drive env vars from arda-secrets
export AWS_ACCESS_KEY_ID="${ARDA_BACKUP_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${ARDA_BACKUP_SECRET_ACCESS_KEY:-}"
export RCLONE_CONFIG_GDRIVE_TYPE=drive
export RCLONE_CONFIG_GDRIVE_SCOPE=drive.file
export RCLONE_CONFIG_GDRIVE_USE_TRASH=false
export RCLONE_CONFIG_GDRIVE_TOKEN="${ARDA_GDRIVE_TOKEN:-}"
export RCLONE_CONFIG_GDRIVE_CLIENT_ID="${ARDA_GDRIVE_CLIENT_ID:-}"
export RCLONE_CONFIG_GDRIVE_CLIENT_SECRET="${ARDA_GDRIVE_CLIENT_SECRET:-}"

REPOS=""
# 1. R2 repositories (omni, lldap, and volsync/* if using R2)
if [ -n "${ARDA_BACKUP_ACCESS_KEY_ID:-}" ] && [ -n "${ARDA_BACKUP_ENDPOINT:-}" ]; then
  for r in omni lldap; do
    uri="s3:${ARDA_BACKUP_ENDPOINT}/arda-backups/$r"
    if RESTIC_REPOSITORY="$uri" RESTIC_PASSWORD_FILE=/tmp/old.pw restic cat config >/dev/null 2>&1 || \
       RESTIC_REPOSITORY="$uri" RESTIC_PASSWORD_FILE=/tmp/new.pw restic cat config >/dev/null 2>&1; then
      REPOS="$REPOS $uri"
    fi
  done
  if [ -z "${ARDA_GDRIVE_TOKEN:-}" ]; then
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${ARDA_BACKUP_ACCESS_KEY_ID}"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${ARDA_BACKUP_SECRET_ACCESS_KEY:-}"
    export RCLONE_CONFIG_R2_ENDPOINT="${ARDA_BACKUP_ENDPOINT}"
    for ns in $(rclone lsf --dirs-only r2:arda-backups/volsync 2>/dev/null | tr -d / || true); do
      for vol in $(rclone lsf --dirs-only "r2:arda-backups/volsync/$ns" 2>/dev/null | tr -d / || true); do
        if rclone lsf "r2:arda-backups/volsync/$ns/$vol" 2>/dev/null | grep -qx config; then
          REPOS="$REPOS s3:${ARDA_BACKUP_ENDPOINT}/arda-backups/volsync/$ns/$vol"
        fi
      done
    done
  fi
fi

# 2. Google Drive repositories (volsync/*)
if [ -n "${ARDA_GDRIVE_TOKEN:-}" ]; then
  for ns in $(rclone lsf --dirs-only gdrive:arda-backups/volsync 2>/dev/null | tr -d / || true); do
    for vol in $(rclone lsf --dirs-only "gdrive:arda-backups/volsync/$ns" 2>/dev/null | tr -d / || true); do
      if rclone lsf "gdrive:arda-backups/volsync/$ns/$vol" 2>/dev/null | grep -qx config; then
        REPOS="$REPOS rclone:gdrive:arda-backups/volsync/$ns/$vol"
      fi
    done
  done
fi

if [ -z "$REPOS" ]; then
  echo "[restic] WARN: No existing restic repositories discovered."
  exit 0
fi

for repo in $REPOS; do
  if [ "$MODE" = "add" ]; then
    echo "[restic] ==> Adding new key to $repo"
    if RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE=/tmp/new.pw restic cat config >/dev/null 2>&1; then
      echo "[restic]   already accepts new password"
    else
      RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE=/tmp/old.pw \
        restic key add --new-password-file /tmp/new.pw >/dev/null
      RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE=/tmp/new.pw restic cat config >/dev/null
      echo "[restic] [OK] added and verified new key on $repo"
    fi
  elif [ "$MODE" = "remove" ]; then
    echo "[restic] ==> Removing old key from $repo"
    # Find the key ID that matches OLD_PW (marked current=true when opened with OLD_PW)
    old_id="$(RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE=/tmp/old.pw \
      restic key list --json 2>/dev/null | jq -r '.[] | select(.current == true) | .id' | head -n1 || true)"
    if [ -n "$old_id" ]; then
      RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE=/tmp/new.pw \
        restic key remove "$old_id" >/dev/null
      echo "[restic] [OK] removed old key $old_id from $repo"
    else
      echo "[restic]   old key already absent on $repo"
    fi
  fi
done
INNER
EOF
}

OLD_B64="$(printf '%s' "$OLD_PW" | base64 | tr -d '\r\n')"
NEW_B64="$(printf '%s' "$NEW_PW" | base64 | tr -d '\r\n')"

# Phase 1 & 2: Add new password & verify on every repo
step "Phase 1/4: Adding new password to every discovered restic repository & verifying..."
emit_restic_op "add" "$OLD_B64" "$NEW_B64" > "$TMP_DIR/add.sh"
ssh_pi_sudo "$AINUR_CP_HOST" "$PUSH_KEY" "$TMP_DIR/add.sh"
ok "Every repository now accepts the new password (old password still valid as fallback)."

# Phase 3: Update .env and sync to ainur + arda
step "Phase 2/4: Backing up .env and writing new ARDA_VOLSYNC_PASSWORD..."
env_backup >/dev/null
env_set "ARDA_VOLSYNC_PASSWORD" "$NEW_PW"
ok "Updated $ENV_FILE"

step "Phase 3/4: Syncing new ARDA_VOLSYNC_PASSWORD to ainur, arda, Kyverno VolSync PVCs, and Backrest..."
# Note: user already individually confirmed ARDA_VOLSYNC_PASSWORD above, so pipe confirmation to sync-env.sh
printf '%s\n' "ARDA_VOLSYNC_PASSWORD" | "$SCRIPT_DIR/sync-env.sh" --only ARDA_VOLSYNC_PASSWORD --env "$ENV_FILE"

# Phase 4: Remove old key from every repo
step "Phase 4/4: Removing old restic key from every repository..."
emit_restic_op "remove" "$OLD_B64" "$NEW_B64" > "$TMP_DIR/remove.sh"
ssh_pi_sudo "$AINUR_CP_HOST" "$PUSH_KEY" "$TMP_DIR/remove.sh"

ok "Tier E ARDA_VOLSYNC_PASSWORD zero-loss rotation complete!"
