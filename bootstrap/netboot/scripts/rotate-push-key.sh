#!/usr/bin/env bash
# Zero-downtime Tier D rotation for AINUR_PUSH_KEY and AINUR_PUSH_PUBKEY.
#
# Steps:
#   1. Generates a fresh Ed25519 keypair locally (in memory/tmpfs, mode 0600).
#   2. Connects to every reachable Pi in PI_HOSTS using the OLD key and appends
#      the NEW pubkey to ~ubuntu/.ssh/authorized_keys.
#   3. Verifies SSH login on every Pi using the NEW key before removing the old.
#   4. Removes the old pubkey from every Pi's authorized_keys.
#   5. Backs up .env and updates AINUR_PUSH_KEY & AINUR_PUSH_PUBKEY in .env.
#   6. Syncs ainur-netboot/ainur-secrets on valar-50 and triggers a fresh
#      pi-netboot-builder Job so netbooted Pis get the new pubkey on next boot.
#
# Usage:
#   ./rotate-push-key.sh [--dry-run] [--skip-confirm] [--env FILE]
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

OLD_KEY="$(env_get AINUR_PUSH_KEY)"
OLD_PUB="$(env_get AINUR_PUSH_PUBKEY)"
if [ -z "$OLD_KEY" ]; then
  err "AINUR_PUSH_KEY is unset in $ENV_FILE — cannot connect with existing key."
  exit 1
fi

banner "Tier D: Zero-Downtime SSH Push Key Rotation" \
  "Targets: $PI_HOSTS_LIST (user: $PI_USER_RESOLVED) | Control plane: $AINUR_CP_HOST"

info "Current AINUR_PUSH_KEY fingerprint:    $(short_hash "$OLD_KEY")"
info "Current AINUR_PUSH_PUBKEY fingerprint: $(short_hash "$OLD_PUB")"
info "Plan:"
detail "1. Generate a new Ed25519 keypair"
detail "2. Authorize the new public key on all reachable Pis ($PI_HOSTS_LIST)"
detail "3. Verify SSH authentication with the new private key"
detail "4. Remove the old public key from authorized_keys"
detail "5. Backup .env, update AINUR_PUSH_KEY + AINUR_PUSH_PUBKEY, sync ainur-netboot/ainur-secrets"
detail "6. Re-trigger pi-netboot-builder Job on ainur so future netboots embed the new pubkey"

if [ "$DRY_RUN" = 1 ]; then
  ok "Dry-run complete — no keys generated or pushed."
  exit 0
fi

if [ "$SKIP_CONFIRM" = 0 ]; then
  confirm_tier "D" "Rotate AINUR_PUSH_KEY / AINUR_PUSH_PUBKEY across all Pis" "2" || exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
umask 077

# --- Step 1: Generate new Ed25519 keypair ----------------------------------
step "Step 1/6: Generating new Ed25519 keypair..."
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N "" -C "ainur-push-$(date +%Y%m%d)" -f "$TMP_DIR/new_key"
else
  MSYS_NO_PATHCONV=1 docker run --rm -v "$TMP_DIR:/k" alpine:3.20 sh -c \
    "apk add -q --no-cache openssh-keygen >/dev/null && ssh-keygen -q -t ed25519 -N '' -C 'ainur-push-$(date +%Y%m%d)' -f /k/new_key"
fi
NEW_KEY="$(base64 < "$TMP_DIR/new_key" | tr -d '\r\n')"
NEW_PUB="$(tr -d '\r\n' < "$TMP_DIR/new_key.pub")"
ok "Generated new keypair (priv hash: $(short_hash "$NEW_KEY"), pub hash: $(short_hash "$NEW_PUB"))"

# --- Step 2: Append new pubkey on every reachable Pi -----------------------
step "Step 2/6: Installing new public key on Pis ($PI_HOSTS_LIST) using OLD key..."
cat > "$TMP_DIR/add-key.sh" <<EOF
set -eu
HOME_DIR="\$(getent passwd "$PI_USER_RESOLVED" | cut -d: -f6)"
AK="\$HOME_DIR/.ssh/authorized_keys"
mkdir -p "\$HOME_DIR/.ssh"
chmod 700 "\$HOME_DIR/.ssh"
touch "\$AK"
if ! grep -Fqx '$NEW_PUB' "\$AK"; then
  printf '%s\n' '$NEW_PUB' >> "\$AK"
fi
chmod 600 "\$AK"
chown -R "${PI_USER_RESOLVED}:${PI_USER_RESOLVED}" "\$HOME_DIR/.ssh"
echo "authorized new key on \$(hostname)"
EOF

declare -a REACHABLE_PIS=()
for ip in $PI_HOSTS_LIST; do
  info "Installing new pubkey on $ip..."
  if ssh_pi_sudo "$ip" "$OLD_KEY" "$TMP_DIR/add-key.sh"; then
    REACHABLE_PIS+=("$ip")
    ok "$ip accepted new public key"
  else
    warn "$ip unreachable with old key (skipping)"
  fi
done

if [ "${#REACHABLE_PIS[@]}" -eq 0 ]; then
  err "No Pis were reachable with the old key! Aborting before modifying .env."
  exit 1
fi

# --- Step 3: Verify login with NEW key on every reachable Pi ---------------
step "Step 3/6: Verifying SSH login with NEW private key before removing old key..."
cat > "$TMP_DIR/verify.sh" <<'EOF'
echo "verified new SSH key on $(hostname) ($(hostname -I | awk '{print $1}'))"
EOF

for ip in "${REACHABLE_PIS[@]}"; do
  if ! ssh_pi_sudo "$ip" "$NEW_KEY" "$TMP_DIR/verify.sh"; then
    err "Verification with NEW key failed on $ip! Aborting — OLD key is still authorized and .env is untouched."
    exit 1
  fi
done
ok "New key verified on all ${#REACHABLE_PIS[@]} reachable Pi(s)."

# --- Step 4: Remove old pubkey from every reachable Pi ---------------------
step "Step 4/6: Removing old public key from authorized_keys..."
if [ -n "$OLD_PUB" ]; then
  cat > "$TMP_DIR/rm-key.sh" <<EOF
set -eu
HOME_DIR="\$(getent passwd "$PI_USER_RESOLVED" | cut -d: -f6)"
AK="\$HOME_DIR/.ssh/authorized_keys"
grep -Fvx '$OLD_PUB' "\$AK" > "\$AK.new"
mv "\$AK.new" "\$AK"
chmod 600 "\$AK"
chown "${PI_USER_RESOLVED}:${PI_USER_RESOLVED}" "\$AK"
echo "removed old key on \$(hostname) (remaining keys: \$(wc -l < "\$AK"))"
EOF
  for ip in "${REACHABLE_PIS[@]}"; do
    ssh_pi_sudo "$ip" "$NEW_KEY" "$TMP_DIR/rm-key.sh"
  done
  ok "Old public key removed from all reachable Pis."
else
  warn "AINUR_PUSH_PUBKEY was empty in .env; skipped old-key removal (remove manually from authorized_keys if needed)."
fi

# --- Step 5: Backup & update .env ------------------------------------------
step "Step 5/6: Backing up .env and writing new AINUR_PUSH_KEY & AINUR_PUSH_PUBKEY..."
env_backup >/dev/null
env_set "AINUR_PUSH_KEY" "$NEW_KEY"
env_set "AINUR_PUSH_PUBKEY" "$NEW_PUB"
ok "Updated $ENV_FILE with new push keypair."

# --- Step 6: Sync ainur-netboot/ainur-secrets & rebuild netboot image ------
step "Step 6/6: Updating ainur-netboot/ainur-secrets on ${AINUR_CP_HOST} and triggering pi-netboot-builder..."
cat > "$TMP_DIR/sync-netboot.sh" <<EOF
set -eu
umask 077
# Update /run/ainur/ainur.env on valar-50 and apply ainur-secrets.service
python3 - <<'PY'
import os
p = "/run/ainur/ainur.env"
kv = {}
order = []
if os.path.isfile(p):
    for line in open(p, encoding="utf-8", errors="replace").read().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            order.append(k)
            kv[k] = v
for k, v in [("AINUR_PUSH_KEY", "$NEW_KEY"), ("AINUR_PUSH_PUBKEY", "$NEW_PUB")]:
    if k not in kv:
        order.append(k)
    kv[k] = v
os.makedirs("/run/ainur", exist_ok=True)
with open(p + ".new", "w", encoding="utf-8") as f:
    for k in order:
        f.write(f"{k}={kv[k]}\n")
os.replace(p + ".new", p)
os.chmod(p, 0o600)
PY
systemctl start ainur-secrets.service
echo "[ainur] [OK] ainur-netboot/ainur-secrets updated (secrets-pusher reads it automatically within 30s)"

# Re-trigger pi-netboot-builder Job so netboot user-data carries the new pubkey
if k3s kubectl -n ainur-netboot get job pi-netboot-builder >/dev/null 2>&1; then
  echo "[ainur] ==> Deleting completed pi-netboot-builder Job and refreshing Argo CD (ainur/pi-netboot)..."
  k3s kubectl -n ainur-netboot delete job pi-netboot-builder --ignore-not-found
  k3s kubectl -n ainur annotate application pi-netboot argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  echo "[ainur] [OK] pi-netboot-builder queued for rebuild (watch with: kubectl -n ainur-netboot get jobs -w)"
fi
EOF
ssh_pi_sudo "$AINUR_CP_HOST" "$NEW_KEY" "$TMP_DIR/sync-netboot.sh"

ok "Tier D SSH push key rotation complete!"
