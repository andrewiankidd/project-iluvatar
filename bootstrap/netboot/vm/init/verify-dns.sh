#!/bin/bash

echo "====================="
echo "verify-dns.sh"
echo "====================="
set -euo pipefail

INFO_IF() { ip -o -4 addr show scope global | awk '{print $2, $4}' ; }

CONF="/etc/dnsmasq.d/proxy-tftp.conf"

fail() { echo "[FAIL] $*"; exit 1; }
pass() { echo "[OK]   $*"; }

echo "1) Checking dnsmasq service status..."
if systemctl is-active --quiet dnsmasq; then
  pass "dnsmasq is active"
else
  echo "[WARN] dnsmasq inactive; attempting render + restart..."
  if [ -x /home/ubuntu/netboot/vm/init/render-dnsmasq.sh ]; then
    sudo /bin/bash /home/ubuntu/netboot/vm/init/render-dnsmasq.sh || true
  fi
  if dnsmasq --test >/dev/null 2>&1; then
    sudo systemctl restart dnsmasq || true
  fi
  if systemctl is-active --quiet dnsmasq; then
    pass "dnsmasq started after render"
  else
    systemctl status dnsmasq --no-pager || true
    journalctl -xeu dnsmasq -n 50 --no-pager || true
    fail "dnsmasq is not active"
  fi
fi

echo "2) Validating config syntax (dnsmasq --test)..."
if dnsmasq --test >/dev/null 2>&1; then
  pass "dnsmasq syntax OK"
else
  dnsmasq --test || true
  fail "dnsmasq syntax check failed"
fi

echo "3) Checking listening sockets (UDP 67, 4011)..."
# Be robust to different ss output formats and scoped/bound addresses
if ss -u -lpnH 'sport = :67' >/dev/null 2>&1 && ss -u -lpnH 'sport = :67' | grep -q .; then
  :
else
  # Fallback parse
  SS_OUT=$(ss -u -lpnH | tr -d '[]' || true)
  echo "$SS_OUT" | grep -Eq '(:|\.)67(\s|$)' || fail "dnsmasq not listening on UDP :67"
fi
if ss -u -lpnH 'sport = :4011' >/dev/null 2>&1 && ss -u -lpnH 'sport = :4011' | grep -q .; then
  :
else
  SS_OUT=${SS_OUT:-$(ss -u -lpnH | tr -d '[]' || true)}
  echo "$SS_OUT" | grep -Eq '(:|\.)4011(\s|$)' || fail "dnsmasq not listening on UDP :4011"
fi
pass "ports 67 and 4011 are listening"

echo "4) Inspecting generated config: $CONF"
if [ ! -f "$CONF" ]; then
  echo "[WARN] $CONF not found; attempting to render now..."
  if [ -x /home/ubuntu/netboot/vm/init/render-dnsmasq.sh ]; then
    sudo /bin/bash /home/ubuntu/netboot/vm/init/render-dnsmasq.sh || true
  fi
fi
test -f "$CONF" || fail "config not found after render: $CONF"
sed -n '1,120p' "$CONF"

echo "5) Deriving current LAN interface and IP..."
# Prefer 192.168.x, then 10.x, else first non-docker/br-
SEL=""
while IFS=' ' read -r IF CIDR; do
  case "$IF" in docker*|veth*|br-*) continue;; esac
  IP=${CIDR%/*}
  case "$IP" in 192.168.*) SEL="$IF $CIDR"; break;; esac
done < <(INFO_IF)
if [ -z "${SEL}" ]; then
  while IFS=' ' read -r IF CIDR; do
    case "$IF" in docker*|veth*|br-*) continue;; esac
    IP=${CIDR%/*}
    case "$IP" in 10.*) SEL="$IF $CIDR"; break;; esac
  done < <(INFO_IF)
fi
if [ -z "${SEL}" ]; then
  SEL=$(INFO_IF | awk '($1!~/(^docker|^veth|^br-)/){print; exit}')
fi
[ -n "${SEL}" ] || fail "no suitable IPv4 interface found"

LAN_IF=$(awk '{print $1}' <<<"$SEL")
CIDR=$(awk '{print $2}' <<<"$SEL")
LAN_IP=${CIDR%/*}
LAN_NET=$(ipcalc -n "$CIDR" | awk -F': *' '/Network/ {print $2}' | cut -d/ -f1)
LAN_MASK=$(ipcalc -m "$CIDR" | awk -F': *' '/Netmask/ {print $2}' | awk '{print $1}')
# If MASK couldn't be derived from ipcalc, parse it from the config's proxy range
if [ -z "$LAN_MASK" ] && [ -f "$CONF" ]; then
  PROXY_LINE=$(grep -E "^dhcp-range=tag:!pxe,set:if-$LAN_IF,$LAN_NET,proxy," "$CONF" | head -n1 || true)
  if [ -n "$PROXY_LINE" ]; then
    LAN_MASK=$(echo "$PROXY_LINE" | awk -F'proxy,' '{print $2}' | awk -F',' '{print $1}')
  fi
fi
echo "Detected: IF=$LAN_IF IP=$LAN_IP NET=$LAN_NET MASK=$LAN_MASK"

echo "6) Verifying required options for $LAN_IF..."
grep -q "^interface=$LAN_IF$" "$CONF" || fail "missing interface=$LAN_IF"
if [ -n "$LAN_MASK" ]; then
  EXPECT_PROXY="^dhcp-range=tag:!pxe,set:if-$LAN_IF,$LAN_NET,proxy,$LAN_MASK$"
  HAS_PROXY=$(grep -E "$EXPECT_PROXY" "$CONF" || true)
else
  HAS_PROXY=$(grep -E "^dhcp-range=tag:!pxe,set:if-$LAN_IF,$LAN_NET,proxy,.*$" "$CONF" || true)
fi
if [ -z "$HAS_PROXY" ]; then
  echo "[WARN] proxy dhcp-range missing or netmask blank; re-rendering config..."
  if [ -x /home/ubuntu/netboot/vm/init/render-dnsmasq.sh ]; then
    sudo DNSMASQ_LAN_IF="$LAN_IF" /bin/bash /home/ubuntu/netboot/vm/init/render-dnsmasq.sh || true
  fi
  if [ -n "$LAN_MASK" ]; then
    grep -Eq "^dhcp-range=tag:!pxe,set:if-$LAN_IF,$LAN_NET,proxy,$LAN_MASK$" "$CONF" || fail "missing proxy dhcp-range for $LAN_IF after render"
  else
    grep -Eq "^dhcp-range=tag:!pxe,set:if-$LAN_IF,$LAN_NET,proxy,.*$" "$CONF" || fail "missing proxy dhcp-range for $LAN_IF after render"
  fi
fi
grep -q "^dhcp-option=tag:if-$LAN_IF,option:tftp-server,$LAN_IP$" "$CONF" || fail "missing option 66 for $LAN_IF"
grep -q "^dhcp-boot=tag:if-$LAN_IF,,,${LAN_IP}$" "$CONF" || fail "missing siaddr dhcp-boot for $LAN_IF"
grep -q "^pxe-service=tag:if-$LAN_IF,0,\"PXE\",,${LAN_IP}$" "$CONF" || fail "missing pxe-service for $LAN_IF"
pass "config lines match $LAN_IF and $LAN_IP"

echo "7) Optional: PXE-only DHCP pool presence (ok if absent on non-/24)..."
if [ "$LAN_MASK" = "255.255.255.0" ]; then
  BASE=$(echo "$LAN_NET" | awk -F. '{print $1"."$2"."$3}')
  POOL_LINE="dhcp-range=tag:pxe,${BASE}.200,${BASE}.220,${LAN_MASK},2m"
  if grep -q "^${POOL_LINE}$" "$CONF"; then
    pass "PXE-only pool present ($POOL_LINE)"
  else
    echo "[WARN] PXE-only pool not found (non-fatal)"
  fi
else
  echo "[INFO] Non-/24 subnet ($LAN_MASK); PXE-only pool may be intentionally omitted"
fi

echo "All checks passed."
