#!/bin/bash

echo "====================="
echo "render-dnsmasq.sh"
echo "====================="
set -euo pipefail

CONF=/etc/dnsmasq.d/proxy-tftp.conf
mkdir -p "$(dirname "$CONF")"

emit_common() {
  echo "bind-interfaces"
  echo "port=0"
  echo "except-interface=lo"
  echo "log-dhcp"
  echo "no-dhcp-interface=docker0"
  echo "no-dhcp-interface=br-*"
  echo "dhcp-authoritative"
  echo "dhcp-match=set:aarch64,60,PXEClient:Arch:00011:UNDI:003000"
  echo "dhcp-vendorclass=set:pxe,PXEClient"
}

# Wait up to 30s for any IPv4 address
for _ in $(seq 1 30); do ip -o -4 addr show scope global | grep -q . && break || sleep 1; done

pick_iface() {
  # If user specified, trust it
  if [ -n "${DNSMASQ_LAN_IF:-}" ]; then
    if ip -o -4 addr show dev "$DNSMASQ_LAN_IF" >/dev/null 2>&1; then
      ip -o -4 addr show dev "$DNSMASQ_LAN_IF" | awk '{print $2, $4}' | head -n1
      return
    fi
  fi
  # Prefer 192.168.x, then 10.x, else first non-docker/br-
  ip -o -4 addr show scope global | awk '$2!~/^(docker|veth|br-)/{print $2, $4}' | awk '$2 ~ /^192\.168\./{print; exit}'
  if [ ${PIPESTATUS[0]} -eq 0 ] && [ ${PIPESTATUS[1]} -eq 0 ]; then return; fi
  ip -o -4 addr show scope global | awk '$2!~/^(docker|veth|br-)/{print $2, $4}' | awk '$2 ~ /^10\./{print; exit}'
  if [ ${PIPESTATUS[0]} -eq 0 ] && [ ${PIPESTATUS[1]} -eq 0 ]; then return; fi
  ip -o -4 addr show scope global | awk '$2!~/^(docker|veth|br-)/{print $2, $4; exit}'
}

SEL=$(pick_iface || true)
if [ -z "${SEL}" ]; then
  emit_common > "$CONF"
  exit 0
fi

IF=$(printf '%s\n' "$SEL" | awk '{print $1}')
CIDR=$(printf '%s\n' "$SEL" | awk '{print $2}')
IP=${CIDR%/*}
NET=$(ipcalc -n "$CIDR" | awk -F': *' '/Network/ {print $2}' | cut -d'/' -f1)
# Derive netmask via ipcalc; this is reliable on Ubuntu
MASK=$(ipcalc -m "$CIDR" | awk -F': *' '/Netmask/ {print $2}' | awk '{print $1}')
if [ -z "${MASK}" ]; then
  # Fallback for safety: assume /24 if ipcalc failed (better than blank)
  MASK=255.255.255.0
fi

# Write config
emit_common > "$CONF"
{
  echo "interface=$IF"
  echo "dhcp-range=tag:!pxe,set:if-$IF,${NET},proxy,${MASK}"
  echo "dhcp-option=tag:if-$IF,option:tftp-server,${IP}"
  echo "dhcp-option-force=tag:if-$IF,66,${IP}"
  echo "dhcp-boot=tag:if-$IF,,,${IP}"
  echo "pxe-service=tag:if-$IF,0,\"PXE\",,${IP}"
  if [ "$MASK" = "255.255.255.0" ]; then
    BASE=$(echo "$NET" | awk -F. '{print $1"."$2"."$3}')
    echo "# PXE-only DHCP pool"
    echo "dhcp-range=tag:pxe,${BASE}.200,${BASE}.220,${MASK},2m"
    echo "dhcp-option=tag:pxe,66,${IP}"
    echo "dhcp-boot=tag:pxe,,,${IP}"
    echo "pxe-service=tag:pxe,0,\"PXE\",,${IP}"
  fi
} >> "$CONF"

# Validate and restart
if dnsmasq --test; then
  systemctl restart dnsmasq || true
else
  echo "dnsmasq config test failed; not restarting"
  exit 1
fi

sed -n '1,200p' "$CONF"
