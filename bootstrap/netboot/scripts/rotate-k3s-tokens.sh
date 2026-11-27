#!/usr/bin/env bash
# Tier D live rotation for AINUR_K3S_TOKEN and AINUR_K3S_AGENT_TOKEN.
#
# Steps:
#   1. Generates fresh 48-char random AINUR_K3S_TOKEN & AINUR_K3S_AGENT_TOKEN
#      (or uses current .env values if --from-env is passed).
#   2. Updates /etc/systemd/system/k3s.service.env (and --token arg if present)
#      on valar-50 and restarts k3s.service, waiting for API /readyz.
#   3. Updates /run/ainur/ainur.env, runs ainur-secrets.service, and restarts
#      ainur-netboot/secrets-pusher so netbooted workers receive the new agent
#      token (from /var/lib/rancher/k3s/server/agent-token).
#   4. Optionally performs a rolling reboot of netbooted worker Pis so they
#      rejoin with the new agent token and derived node password.
#
# Usage:
#   ./rotate-k3s-tokens.sh [--from-env] [--dry-run] [--skip-confirm] [--env FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rotate-common.sh
. "$SCRIPT_DIR/lib/rotate-common.sh"

FROM_ENV=0
DRY_RUN=0
SKIP_CONFIRM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from-env) FROM_ENV=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-confirm) SKIP_CONFIRM=1 ;;
    --env) ENV_FILE="${2:?missing value for --env}"; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--from-env] [--dry-run] [--skip-confirm] [--env PATH]"
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

require_env_file
resolve_pi_targets

PUSH_KEY="$(env_get AINUR_PUSH_KEY)"
if [ -z "$PUSH_KEY" ]; then
  err "AINUR_PUSH_KEY is unset in $ENV_FILE."
  exit 1
fi

banner "Tier D: k3s Server & Agent Token Rotation" \
  "Control plane: $AINUR_CP_HOST | All Pis: $PI_HOSTS_LIST"

if [ "$FROM_ENV" = 1 ]; then
  NEW_SERVER_TOKEN="$(env_get AINUR_K3S_TOKEN)"
  NEW_AGENT_TOKEN="$(env_get AINUR_K3S_AGENT_TOKEN)"
  info "Mode: applying existing .env values (--from-env)"
else
  NEW_SERVER_TOKEN="$(rand_alnum 48)"
  NEW_AGENT_TOKEN="$(rand_alnum 48)"
  info "Mode: generating fresh 48-char random AINUR_K3S_TOKEN & AINUR_K3S_AGENT_TOKEN"
fi

if [ -z "$NEW_SERVER_TOKEN" ] || [ -z "$NEW_AGENT_TOKEN" ]; then
  err "Server or agent token is empty; aborting."
  exit 1
fi

info "New AINUR_K3S_TOKEN fingerprint:       $(short_hash "$NEW_SERVER_TOKEN")"
info "New AINUR_K3S_AGENT_TOKEN fingerprint: $(short_hash "$NEW_AGENT_TOKEN")"
warn "This will briefly restart k3s on $AINUR_CP_HOST (~15-30s API pause); existing pods stay running."

if [ "$DRY_RUN" = 1 ]; then
  ok "Dry-run complete — no changes applied."
  exit 0
fi

if [ "$SKIP_CONFIRM" = 0 ]; then
  confirm_tier "D" "Rotate AINUR_K3S_TOKEN & AINUR_K3S_AGENT_TOKEN on $AINUR_CP_HOST" "2" || exit 0
fi

if [ "$FROM_ENV" = 0 ]; then
  step "Step 1/4: Backing up .env and writing new k3s tokens..."
  env_backup >/dev/null
  env_set "AINUR_K3S_TOKEN" "$NEW_SERVER_TOKEN"
  env_set "AINUR_K3S_AGENT_TOKEN" "$NEW_AGENT_TOKEN"
  ok "Updated $ENV_FILE"
else
  step "Step 1/4: Using existing tokens from $ENV_FILE..."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

step "Step 2/4: Applying new k3s tokens on ${AINUR_CP_HOST} and restarting k3s..."
cat > "$TMP_DIR/rotate-k3s.sh" <<EOF
set -eu
umask 077

# Update k3s systemd env file + any inline --token arg in k3s.service
ENVF=/etc/systemd/system/k3s.service.env
SVC=/etc/systemd/system/k3s.service
touch "\$ENVF"
chmod 600 "\$ENVF"

python3 - "\$ENVF" "\$SVC" "$NEW_SERVER_TOKEN" "$NEW_AGENT_TOKEN" <<'PY'
import re, sys
envf, svc, stok, atok = sys.argv[1:5]

# Update k3s.service.env
lines = open(envf, encoding="utf-8", errors="replace").read().splitlines()
out = [l for l in lines if not l.startswith(("K3S_TOKEN=", "K3S_AGENT_TOKEN="))]
out.append(f"K3S_TOKEN={stok}")
out.append(f"K3S_AGENT_TOKEN={atok}")
open(envf, "w", encoding="utf-8").write("\n".join(out) + "\n")

# Update any inline --token <old> in k3s.service (if user-data wrote it there)
txt = open(svc, encoding="utf-8", errors="replace").read()
new_txt = re.sub(r"(--token(?:=|\s+))'[^']*'", r"\g<1>'" + stok + "'", txt)
new_txt = re.sub(r"(--token(?:=|\s+))\"[^\"]*\"", r'\g<1>"' + stok + '"', new_txt)
new_txt = re.sub(r"(--token(?:=|\s+))([^\s'\"\\\\]+)", r"\g<1>" + stok, new_txt)
if new_txt != txt:
    open(svc, "w", encoding="utf-8").write(new_txt)
    print("[ainur] Updated --token in k3s.service")
PY

# Clean up any world-readable legacy token copies in /tmp/k3s
rm -f /tmp/k3s/k3s-token /tmp/k3s/k3s-agent-token

echo "[ainur] ==> Reloading systemd and restarting k3s.service..."
systemctl daemon-reload
systemctl restart k3s.service

echo "[ainur]   Waiting for k3s API /readyz..."
for i in \$(seq 1 90); do
  if k3s kubectl --request-timeout=5s get --raw=/readyz 2>/dev/null | grep -qx ok; then
    echo "[ainur] [OK] k3s API is ready"
    break
  fi
  sleep 2
done

# Update /run/ainur/ainur.env + ainur-secrets.service + restart secrets-pusher
python3 - "$NEW_SERVER_TOKEN" "$NEW_AGENT_TOKEN" <<'PY'
import os, sys
stok, atok = sys.argv[1], sys.argv[2]
p = "/run/ainur/ainur.env"
kv, order = {}, []
if os.path.isfile(p):
    for l in open(p, encoding="utf-8", errors="replace").read().splitlines():
        if "=" in l and not l.lstrip().startswith("#"):
            k, v = l.split("=", 1)
            order.append(k); kv[k] = v
for k, v in [("AINUR_K3S_TOKEN", stok), ("AINUR_K3S_AGENT_TOKEN", atok)]:
    if k not in kv: order.append(k)
    kv[k] = v
os.makedirs("/run/ainur", exist_ok=True)
with open(p + ".new", "w", encoding="utf-8") as f:
    for k in order: f.write(f"{k}={kv[k]}\n")
os.replace(p + ".new", p)
os.chmod(p, 0o600)
PY
systemctl start ainur-secrets.service
if k3s kubectl -n ainur-netboot get deploy/secrets-pusher >/dev/null 2>&1; then
  k3s kubectl -n ainur-netboot rollout restart deploy/secrets-pusher
  k3s kubectl -n ainur-netboot rollout status deploy/secrets-pusher --timeout=90s
fi
echo "[ainur] [OK] k3s tokens rotated on server and secrets-pusher restarted"
EOF

ssh_pi_sudo "$AINUR_CP_HOST" "$PUSH_KEY" "$TMP_DIR/rotate-k3s.sh"

step "Step 3/4: Checking netbooted worker Pis..."
WORKERS=()
for ip in $PI_HOSTS_LIST; do
  [ "$ip" = "$AINUR_CP_HOST" ] && continue
  WORKERS+=("$ip")
done

if [ "${#WORKERS[@]}" -gt 0 ]; then
  info "Netbooted workers (${WORKERS[*]}) derive /etc/rancher/node/password from the agent token on boot."
  info "They will stay connected until rebooted, and secrets-pusher will hand them the new token automatically on reboot."
  ans=""
  read -r -p "Perform a rolling reboot of worker Pis (${WORKERS[*]}) now to verify rejoin? [y/N]: " ans
  if [[ "${ans,,}" =~ ^(y|yes)$ ]]; then
    cat > "$TMP_DIR/reboot.sh" <<'EOF'
echo "rebooting $(hostname)..."
nohup sh -c 'sleep 2 && systemctl reboot' >/dev/null 2>&1 &
EOF
    for ip in "${WORKERS[@]}"; do
      step "Rebooting worker $ip..."
      ssh_pi_sudo "$ip" "$PUSH_KEY" "$TMP_DIR/reboot.sh" || warn "$ip unreachable"
      info "Waiting 60s before next worker so cluster stays healthy..."
      sleep 60
    done
  else
    info "Skipped worker reboots — they will pick up the new agent token on their next reboot."
  fi
fi

step "Step 4/4: Done!"
ok "Tier D k3s token rotation finished."
