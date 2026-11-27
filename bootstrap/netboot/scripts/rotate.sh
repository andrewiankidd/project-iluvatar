#!/usr/bin/env bash
# Unified entrypoint for ALL project-iluvatar secret rotation & live-cluster
# force-sync operations.
#
# Confirmation model:
#   - Tier B (standard Secret sync + restarts):      ONE-TIME confirmation
#   - Tier C (stateful in-app DB/API reconciliation): ONE-TIME confirmation
#   - Tier D (Pi SSH push key + k3s tokens):         ONE-TIME confirmation
#   - Tier E (highest tier — encryption/trust roots): INDIVIDUAL confirmation
#                                                     per variable (type exact name)
#
# Subcommands:
#   ./rotate.sh [all] [--dry-run]            Guided walkthrough across Tiers B -> C -> D -> E
#   ./rotate.sh sync [sync-env.sh flags]     Force local .env values onto live ainur & arda
#   ./rotate.sh core [--dry-run]             Rotate core cluster auth, alert, and k3s join secrets
#   ./rotate.sh admin-password [--generate]  Rotate admin password (LLDAP + ntfy via set-admin-password.sh)
#   ./rotate.sh push-key [--dry-run]         Rotate AINUR_PUSH_KEY / AINUR_PUSH_PUBKEY across all Pis
#   ./rotate.sh k3s-tokens [--dry-run]       Rotate AINUR_K3S_TOKEN / AINUR_K3S_AGENT_TOKEN
#   ./rotate.sh restic-password [--dry-run]  Zero-loss rotation of ARDA_VOLSYNC_PASSWORD across all repos
#   ./rotate.sh inventory                    Print full variable tier/target/reload inventory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rotate-common.sh
. "$SCRIPT_DIR/lib/rotate-common.sh"

DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  all (default)     Guided rotation across ALL tiers (B -> C -> D -> E):
                      * Tier B: one-time prompt (standard lab-owned secrets)
                      * Tier C: one-time prompt (stateful DB/API secrets)
                      * Tier D: one-time prompt (Pi SSH push key + k3s tokens)
                      * Tier E: individual confirmation per entry (restic key, LLDAP key seed, Lab CA)
  sync              Force local .env values onto running ainur & arda (delegates to sync-env.sh)
  core              Rotate core cluster auth, alert, and k3s join secrets + sync live
  admin-password    Rotate admin password across LLDAP + ntfy (delegates to set-admin-password.sh)
  push-key          Zero-downtime rotation of AINUR_PUSH_KEY / AINUR_PUSH_PUBKEY
  k3s-tokens        Live rotation of AINUR_K3S_TOKEN / AINUR_K3S_AGENT_TOKEN
  restic-password   Zero-loss rotation of ARDA_VOLSYNC_PASSWORD across every restic repo
  inventory         Print full Phase 1 variable inventory (tiers, destinations, reload behavior)

Common options:
  --dry-run         Preview every planned action without modifying .env or clusters
  --env PATH        Path to .env file (default: $ENV_FILE)
  -h, --help        Show this help
EOF
}

CMD="${1:-all}"
if [ $# -gt 0 ]; then shift; fi

case "$CMD" in
  -h|--help) usage; exit 0 ;;
  sync)
    exec "$SCRIPT_DIR/sync-env.sh" "$@" ;;
  admin-password)
    exec "$SCRIPT_DIR/set-admin-password.sh" "$@" ;;
  push-key)
    exec "$SCRIPT_DIR/rotate-push-key.sh" "$@" ;;
  k3s-tokens)
    exec "$SCRIPT_DIR/rotate-k3s-tokens.sh" "$@" ;;
  restic-password)
    exec "$SCRIPT_DIR/rotate-restic-password.sh" "$@" ;;
esac

# Parse remaining flags for all / core / inventory
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --env) ENV_FILE="${2:?missing value for --env}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option for '$CMD': $1"; usage; exit 1 ;;
  esac
  shift
done

# --- Inventory Subcommand --------------------------------------------------
cmd_inventory() {
  local src="$NETBOOT_DIR/.env.example"
  banner "Phase 1 Inventory: .env Variables by Rotability Tier" "Reference: $src"
  local keys
  keys="$(sed -nE 's/^#?\s*([A-Z][A-Z0-9_]+)=.*$/\1/p' "$src" | awk '!seen[$0]++')"
  for tier in B C D E A; do
    case "$tier" in
      B) section "Tier B — Live-Rotatable via Secret Sync + Rollout Restart (1x Tier Confirmation)" ;;
      C) section "Tier C — Live-Rotatable WITH In-App DB/API Reconciliation (1x Tier Confirmation)" ;;
      D) section "Tier D — Pi Host / k3s Cluster-Level Credentials (1x Tier Confirmation)" ;;
      E) section "Tier E — HIGHEST TIER: Encryption & Trust Roots (INDIVIDUAL Entry Confirmation)" ;;
      A) section "Tier A — Bootstrap VM / Build-Only (Not Pushed to Running Clusters)" ;;
    esac
    for k in $keys; do
      [ "$(var_tier "$k")" = "$tier" ] || continue
      printf '  %s%-33s%s [%-12s] %s\n' "$C_BOLD" "$k" "$C_RESET" "$(var_cluster "$k")" "$(var_summary "$k")"
    done
  done
  exit 0
}

if [ "$CMD" = "inventory" ]; then
  cmd_inventory
fi

require_env_file
resolve_pi_targets

# Generate a fresh value appropriate for a given lab-owned variable name.
gen_value_for() {
  case "$1" in
    AINUR_NTFY_TOKEN) rand_ntfy_token ;;
    ARDA_PAPERLESS_SCANNER_PASSWORD) rand_alnum 20 ;; # short enough to type on a scanner panel
    ARDA_PAPERLESS_SECRET_KEY) rand_alnum 50 ;;
    AINUR_SSO_SECRET|AINUR_OIDC_CLIENT_SECRET|AINUR_LLDAP_JWT_SECRET|AINUR_LLDAP_KEY_SEED) rand_hex 32 ;;
    *) rand_alnum 32 ;;
  esac
}

# Only rotate keys that are actually populated in .env (don't activate unused optional apps).
filter_populated() {
  local out=() k v
  for k in "$@"; do
    v="$(env_get "$k")"
    if [ -n "$v" ]; then
      out+=("$k")
    else
      detail "Skipping $k (currently unset/empty in .env)"
    fi
  done
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

# Helper to regenerate a list of keys into .env and push them live via sync-env.sh
rotate_key_group() {
  local tier="$1" title="$2"
  shift 2
  local candidates=("$@")
  local active=() line
  while IFS= read -r line; do
    [ -n "$line" ] && active+=("$line")
  done < <(filter_populated "${candidates[@]}")

  section "Tier $tier — $title (${#active[@]} populated key(s))"
  if [ "${#active[@]}" -eq 0 ]; then
    info "No populated keys in this tier to rotate."
    return 0
  fi

  for k in "${active[@]}"; do
    printf '  %s%-33s%s (%s) current:%s\n' \
      "$C_BOLD" "$k" "$C_RESET" "$(var_cluster "$k")" "$(short_hash "$(env_get "$k")")"
    detail "$(var_summary "$k")"
  done

  if [ "$DRY_RUN" = 1 ]; then
    info "[DRY-RUN] Would generate fresh random values for: ${active[*]} and run sync-env.sh"
    return 0
  fi

  if ! confirm_tier "$tier" "$title" "${#active[@]}"; then
    return 0
  fi

  if [ "$BACKUP_DONE" = 0 ]; then
    env_backup >/dev/null
    BACKUP_DONE=1
  fi

  local csv=""
  for k in "${active[@]}"; do
    local new_val
    new_val="$(gen_value_for "$k")"
    env_set "$k" "$new_val"
    ok "Generated new $k in .env (fingerprint: $(short_hash "$new_val"))"
    csv="${csv:+${csv},}${k}"
  done

  step "Forcing rotated Tier $tier keys onto running clusters..."
  "$SCRIPT_DIR/sync-env.sh" --only "$csv" --preconfirmed-tiers "$tier" --env "$ENV_FILE"
}

BACKUP_DONE=0

# --- Preset: core ----------------------------------------------------------
if [ "$CMD" = "core" ]; then
  banner "project-iluvatar: Core Cluster Secret Rotation" \
    "Rotates core cluster auth, alert, and k3s join secrets | Mode: $([ "$DRY_RUN" = 1 ] && echo 'DRY-RUN' || echo 'LIVE')"

  info "This preset covers:"
  detail "Tier B: AINUR_OIDC_CLIENT_SECRET, AINUR_SSO_SECRET, AINUR_NTFY_TOKEN, AINUR_LLDAP_JWT_SECRET"
  detail "Tier C: AINUR_LLDAP_DEX_PASSWORD (+ Transmute admin password via AINUR_SSO_SECRET)"
  detail "Tier D: AINUR_K3S_TOKEN & AINUR_K3S_AGENT_TOKEN"
  detail "(For your human admin password, also run './rotate.sh admin-password' if not yet changed.)"

  rotate_key_group "B" "Core Cluster Secrets (OIDC, SSO, ntfy, LLDAP JWT)" \
    AINUR_OIDC_CLIENT_SECRET AINUR_SSO_SECRET AINUR_NTFY_TOKEN AINUR_LLDAP_JWT_SECRET

  rotate_key_group "C" "Core LLDAP Dex Bind Password" \
    AINUR_LLDAP_DEX_PASSWORD

  section "Tier D — Core k3s Server & Agent Tokens (2 keys)"
  info "AINUR_K3S_TOKEN & AINUR_K3S_AGENT_TOKEN"
  detail "$(var_summary AINUR_K3S_TOKEN)"
  detail "$(var_summary AINUR_K3S_AGENT_TOKEN)"
  if [ "$DRY_RUN" = 1 ]; then
    info "[DRY-RUN] Would run rotate-k3s-tokens.sh"
  elif confirm_tier "D" "Rotate AINUR_K3S_TOKEN & AINUR_K3S_AGENT_TOKEN" "2"; then
    "$SCRIPT_DIR/rotate-k3s-tokens.sh" --skip-confirm --env "$ENV_FILE"
  fi

  banner "Core Cluster Rotation Complete" \
    "Note: External SaaS tokens (Cloudflare, UniFi, GitLab, Mullvad, Google Drive, R2) must be rotated in their provider portals, then pushed with './rotate.sh sync'."
  exit 0
fi

# --- Command: all (Full Tier B -> C -> D -> E Walkthrough) -----------------
if [ "$CMD" = "all" ]; then
  banner "project-iluvatar: Full Secret Rotation Walkthrough (Tiers B -> C -> D -> E)" \
    "Source: $ENV_FILE | Control plane: $AINUR_CP_HOST | Mode: $([ "$DRY_RUN" = 1 ] && echo 'DRY-RUN' || echo 'LIVE')"

  info "External third-party tokens (Cloudflare, UniFi, GitLab, Mullvad, R2, Google Drive, ComicVine)"
  info "cannot be generated locally — rotate those in their web portals, paste into .env, and run './rotate.sh sync'."
  info "First, checking if .env already has unpushed edits compared to the live cluster..."

  # Offer to sync any manually edited .env values first? Show dry-run diff so user has full visibility!
  "$SCRIPT_DIR/sync-env.sh" --dry-run --env "$ENV_FILE" || warn "Could not probe live cluster diff (continuing)."

  # --- TIER B (One-time confirmation) --------------------------------------
  rotate_key_group "B" "Standard Lab-Owned Secrets (Secret Sync + Rollout Restarts)" \
    AINUR_OIDC_CLIENT_SECRET \
    AINUR_SSO_SECRET \
    AINUR_NTFY_TOKEN \
    AINUR_LLDAP_JWT_SECRET \
    ARDA_PAPERLESS_SECRET_KEY \
    ARDA_PAPERLESS_SCANNER_PASSWORD \
    ARDA_OBSIDIAN_PASSWORD \
    ARDA_DRAGONWILDS_ADMIN_PASSWORD

  # --- TIER C (One-time confirmation) --------------------------------------
  rotate_key_group "C" "Stateful App Secrets (In-App DB / API Reconciliation)" \
    AINUR_LLDAP_DEX_PASSWORD \
    ARDA_PAPERLESS_ADMIN_PASSWORD \
    ARDA_HOMEASSISTANT_PASSWORD \
    ARDA_MEDIA_API_SECRET

  # --- TIER D (One-time confirmation) --------------------------------------
  section "Tier D — Pi Host & k3s Cluster Credentials (4 keys)"
  info "  AINUR_PUSH_KEY / AINUR_PUSH_PUBKEY      — zero-downtime Ed25519 cutover across $PI_HOSTS_LIST"
  info "  AINUR_K3S_TOKEN / AINUR_K3S_AGENT_TOKEN — k3s server/agent token rotation on $AINUR_CP_HOST"
  if [ "$DRY_RUN" = 1 ]; then
    info "[DRY-RUN] Would run rotate-push-key.sh and rotate-k3s-tokens.sh"
  elif confirm_tier "D" "Pi SSH Push Key & k3s Tokens" "4"; then
    "$SCRIPT_DIR/rotate-push-key.sh" --skip-confirm --env "$ENV_FILE"
    "$SCRIPT_DIR/rotate-k3s-tokens.sh" --skip-confirm --env "$ENV_FILE"
  fi

  # --- TIER E (HIGHEST TIER — Individual confirmation per entry!) ----------
  section "Tier E — HIGHEST TIER: Encryption & Trust Roots (Individual Confirmation Per Entry)"
  warn "Every Tier E variable below is prompted INDIVIDUALLY and requires typing its exact name."

  # Entry E-1: ARDA_VOLSYNC_PASSWORD
  if [ -n "$(env_get ARDA_VOLSYNC_PASSWORD)" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "[DRY-RUN] Tier E entry #1: ARDA_VOLSYNC_PASSWORD -> would prompt individually and run rotate-restic-password.sh"
    elif confirm_tier_e_entry "ARDA_VOLSYNC_PASSWORD" "$(var_tier_e_warning ARDA_VOLSYNC_PASSWORD)"; then
      "$SCRIPT_DIR/rotate-restic-password.sh" --skip-confirm --env "$ENV_FILE"
    fi
  fi

  # Entry E-2: AINUR_LLDAP_KEY_SEED
  if [ -n "$(env_get AINUR_LLDAP_KEY_SEED)" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "[DRY-RUN] Tier E entry #2: AINUR_LLDAP_KEY_SEED -> would prompt individually (DESTRUCTIVE: resets all LLDAP user passwords)"
    elif confirm_tier_e_entry "AINUR_LLDAP_KEY_SEED" "$(var_tier_e_warning AINUR_LLDAP_KEY_SEED)"; then
      if [ "$BACKUP_DONE" = 0 ]; then env_backup >/dev/null; BACKUP_DONE=1; fi
      new_seed="$(gen_value_for AINUR_LLDAP_KEY_SEED)"
      env_set "AINUR_LLDAP_KEY_SEED" "$new_seed"
      ok "Generated new AINUR_LLDAP_KEY_SEED in .env (fingerprint: $(short_hash "$new_seed"))"
      printf '%s\n' "AINUR_LLDAP_KEY_SEED" | "$SCRIPT_DIR/sync-env.sh" --only AINUR_LLDAP_KEY_SEED --env "$ENV_FILE"
      warn "Reminder: all non-admin LLDAP users must have their passwords re-set in https://lldap.kidd.network (admin resets automatically)."
    fi
  fi

  # Entry E-3: AINUR_LAB_CA_CRT / AINUR_LAB_CA_KEY
  if [ -n "$(env_get AINUR_LAB_CA_CRT)" ]; then
    info "Tier E entry #3: AINUR_LAB_CA_CRT / AINUR_LAB_CA_KEY"
    detail "Lab Root CA rotation requires a dual-CA trust transition across Talos nodes, cert-manager, and user devices."
    detail "To push a manually prepared CA from .env onto ainur, run: ./rotate.sh sync --only AINUR_LAB_CA_CRT,AINUR_LAB_CA_KEY"
  fi

  # Optional: Human admin password (LLDAP + ntfy)
  section "Optional — Admin Login Password (AINUR_LLDAP_ADMIN_PASSWORD + AINUR_DEX_ADMIN_HASH)"
  info "Changes your personal login password in LLDAP (Dex) and ntfy via set-admin-password.sh."
  if [ "$DRY_RUN" = 1 ]; then
    info "[DRY-RUN] Would offer to run set-admin-password.sh"
  else
    ans=""
    read -r -p "Also rotate your admin login password now? [y/N]: " ans
    if [[ "${ans,,}" =~ ^(y|yes)$ ]]; then
      "$SCRIPT_DIR/set-admin-password.sh"
    else
      info "Skipped admin password rotation (run './rotate.sh admin-password' any time)."
    fi
  fi

  banner "Rotation Walkthrough Finished" \
    "Reminders: (1) Save updated .env securely; (2) If ARDA_OBSIDIAN_PASSWORD changed, update Obsidian LiveSync; (3) If ARDA_PAPERLESS_SCANNER_PASSWORD changed, update your scanner."
  exit 0
fi

err "Unknown command: $CMD"
usage
exit 1
