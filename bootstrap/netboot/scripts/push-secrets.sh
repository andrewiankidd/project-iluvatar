#!/bin/sh
# Hands the Pis their secrets over SSH, so no image and no web server holds
# them. A Pi's image trusts only AINUR_PUSH_PUBKEY; when it boots it waits,
# leaving /run/ainur/awaiting-push ("sd" or "netboot"), until a pusher with
# the matching private key (AINUR_PUSH_KEY) SSHes in and writes /run/ainur/.
#
# Two pushers run this:
#   full   the bootstrap VM (docker-compose.yml), with all of .env, read again
#          every round, so a value added there reaches ainur within a minute:
#            k3s.env    the agent token to a waiting Pi; the server token too
#                       to the SD card Pi, which becomes the k3s server
#            ainur.env  every AINUR_* value, which ainur-secrets.sh makes into
#            arda.env   ainur's Secrets, and every ARDA_*, for arda-secrets.sh;
#                       to the k3s server, or a Pi about to become it
#   agent  ainur itself (src/manifests/ainur/pi-netboot/secrets-pusher.yaml),
#          with only the agent token: a netbooted Pi forgets everything when
#          it reboots, and has to be handed the token again every boot.
#
# The Pis are found, not listed: every host on this /24 whose SSH says
# Ubuntu, and which takes the key. One that doesn't is left alone for an hour.
#
# The pusher can't tell a Pi from something pretending to be one: a netbooted
# Pi makes new SSH host keys every boot. Taking a push means answering SSH as
# a Pi, with the right address, while one boots; reading /secrets took one
# curl at any time. See BACKLOG.md ("Secrets").
set -u
# PID 1 in its container: without this it ignores SIGTERM and is killed late.
trap 'exit 0' TERM INT

MODE="${PUSH_MODE:-agent}"
INTERVAL="${PUSH_INTERVAL:-30}"
ENV_FILE="${PUSH_ENV_FILE:-}"
# This /24: the VM's own address, or (on ainur) the node's.
NET="${PUSH_NET:-${HOST_IP:-${BOOTSTRAP_IP_ADDRESS:-}}}"
NET="${NET%.*}"
STATE=/tmp/push-secrets
mkdir -p "$STATE/refused"

log() { echo "[push-secrets] $(date -Iseconds) $*"; }

# The values, fresh each round: from the .env file (the VM), or from a
# mounted Secret, a file per value (ainur's pod), so a changed value is used
# without a restart.
ENV_DIR="${PUSH_ENV_DIR:-}"
values() {
	if [ -n "$ENV_FILE" ]; then
		[ -r "$ENV_FILE" ] || { log "can't read $ENV_FILE"; return 1; }
		# shellcheck disable=SC1090
		( set -a; . "$ENV_FILE" >/dev/null 2>&1; env ) | grep -E '^(AINUR|ARDA)_[A-Z0-9_]*=' | sort
	elif [ -n "$ENV_DIR" ]; then
		for f in "$ENV_DIR"/AINUR_* "$ENV_DIR"/ARDA_*; do
			[ -f "$f" ] && printf '%s=%s\n' "${f##*/}" "$(cat "$f")"
		done
	fi
}
value() { printf '%s\n' "$VALUES" | grep "^$1=" | head -n1 | cut -d= -f2-; }

[ -n "$NET" ] || { log "no address to scan from (PUSH_NET, HOST_IP or BOOTSTRAP_IP_ADDRESS)"; exit 1; }
log "mode $MODE, scanning $NET.0/24 every ${INTERVAL}s"

while :; do
	VALUES="$(values || true)"
	KEY="$(value AINUR_PUSH_KEY)"
	AGENT_TOKEN="$(value AINUR_K3S_AGENT_TOKEN)"
	if [ -z "$KEY" ] || [ -z "$AGENT_TOKEN" ]; then
		log "AINUR_PUSH_KEY or AINUR_K3S_AGENT_TOKEN missing; nothing to push"
		sleep "$INTERVAL" & wait $!; continue
	fi
	printf '%s\n' "$KEY" | base64 -d > "$STATE/key" 2>/dev/null && chmod 600 "$STATE/key"

	# What a waiting Pi gets: a netbooted one the agent token, the SD card Pi
	# (the k3s server to be) the server token too, from the VM only.
	agent_env="AINUR_K3S_AGENT_TOKEN=$AGENT_TOKEN"
	server_env=""
	ainur_env=""; arda_env=""; envsum=""
	if [ "$MODE" = full ]; then
		server_env="$agent_env
AINUR_K3S_TOKEN=$(value AINUR_K3S_TOKEN)"
		ainur_env="$(printf '%s\n' "$VALUES" | grep '^AINUR_')"
		arda_env="$(printf '%s\n' "$VALUES" | grep '^ARDA_')"
		envsum="$(printf '%s\n%s\n' "$ainur_env" "$arda_env" | sha256sum | cut -d' ' -f1)"
	fi
	b64() { printf '%s\n' "$1" | base64 | tr -d '\n'; }

	# Run on the Pi as root. Writes only what's missing or changed.
	remote="set -eu
mkdir -p /run/ainur; chmod 700 /run/ainur; umask 077
want=\$(cat /run/ainur/awaiting-push 2>/dev/null || true)
server=; [ -f /etc/rancher/k3s/k3s.yaml ] && server=1
if [ -n '$envsum' ] && { [ \"\$want\" = sd ] || [ -n \"\$server\" ]; } \\
   && [ \"\$(cat /run/ainur/env.sha256 2>/dev/null || true)\" != '$envsum' ]; then
  echo '$(b64 "$ainur_env")' | base64 -d > /run/ainur/ainur.env.new && mv /run/ainur/ainur.env.new /run/ainur/ainur.env
  echo '$(b64 "$arda_env")' | base64 -d > /run/ainur/arda.env.new && mv /run/ainur/arda.env.new /run/ainur/arda.env
  echo '$envsum' > /run/ainur/env.sha256
  echo 'pushed ainur.env and arda.env'
  if [ -n \"\$server\" ]; then systemctl start ainur-secrets.service arda-secrets.service && echo 'applied them'; fi
fi
if [ \"\$want\" = netboot ]; then
  echo '$(b64 "$agent_env")' | base64 -d > /run/ainur/k3s.env.new && mv /run/ainur/k3s.env.new /run/ainur/k3s.env
  rm -f /run/ainur/awaiting-push
  echo 'pushed the k3s agent token (netboot)'
elif [ \"\$want\" = sd ] && [ '$MODE' = full ]; then
  echo '$(b64 "$server_env")' | base64 -d > /run/ainur/k3s.env.new && mv /run/ainur/k3s.env.new /run/ainur/k3s.env
  rm -f /run/ainur/awaiting-push
  echo 'pushed the k3s tokens (sd)'
elif [ \"\$want\" = sd ]; then
  echo 'waiting for the k3s server token, which only the bootstrap VM has'
fi"

	# Every SSH server here that says Ubuntu, then those that take the key.
	seq 1 254 | sed "s/^/$NET./" > "$STATE/hosts"
	ssh-keyscan -T 3 -t ed25519 -f "$STATE/hosts" > "$STATE/scan" 2>&1
	sed -n 's/^# \([0-9.]*\):22 SSH-2.0-.*[Uu]buntu.*/\1/p' "$STATE/scan" | sort -u > "$STATE/ubuntu"
	now=$(date +%s)
	while read -r ip; do
		since=$(cat "$STATE/refused/$ip" 2>/dev/null || echo 0)
		[ $((now - since)) -ge 3600 ] || continue
		if ! out=$(printf '%s\n' "$remote" | ssh -i "$STATE/key" -o BatchMode=yes -o IdentitiesOnly=yes \
			-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
			-o ConnectTimeout=5 "ubuntu@$ip" 'sudo sh' 2>&1); then
			case "$out" in
				*"Permission denied"*) echo "$now" > "$STATE/refused/$ip" ;;
				*) log "$ip: failed: $out" ;;
			esac
			continue
		fi
		if [ -n "$out" ]; then printf '%s\n' "$out" | sed "s/^/[push-secrets] $(date -Iseconds) $ip: /"; fi
	done < "$STATE/ubuntu"
	sleep "$INTERVAL" & wait $!
done
