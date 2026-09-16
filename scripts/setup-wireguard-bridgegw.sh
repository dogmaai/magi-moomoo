#!/bin/bash
# setup-wireguard-bridgegw.sh — WireGuard server + TCP relay on the bridge-gw
# GCE VM (Debian 12, magi-vpc 10.42.0.10) for magi-moomoo#66 phase P3.
#
# Run ON the bridge-gw VM (after Jun creates it per the plan comment):
#   gcloud compute ssh bridge-gw --zone=asia-northeast1-a
#
# Bootstrap (no client key yet — prints WG_SERVER_PUBKEY for TIALA):
#   sudo bash setup-wireguard-bridgegw.sh
# Register TIALA's key (re-run once the TIALA script prints WG_CLIENT_PUBKEY):
#   sudo bash setup-wireguard-bridgegw.sh <WG_CLIENT_PUBKEY>
#
# What it does:
#   1. apt install wireguard nftables
#   2. Generate server keypair (if absent); print WG_SERVER_PUBKEY for TIALA
#   3. Write /etc/wireguard/wg0.conf (server 10.99.0.1; [Peer] added only when
#      the client key is supplied — bootstrap run produces a peer-less conf)
#   4. Enable IP forwarding + DNAT  tcp/11436 -> 10.99.0.2:11436, restricted
#      to VPC sources (10.42.0.0/24), inside a dedicated nftables table so
#      existing firewall rules are never touched
#   5. Restart wg-quick@wg0 so conf rewrites always take effect; verify
#
# magi-moomoo then reaches the bridge as http://10.42.0.10:11436 — the DNAT
# makes the VM's VPC address the fixed private endpoint.
#
# Args/env:
#   $1 / WG_CLIENT_PUBKEY  TIALA's client public key (positional arg survives
#                          `sudo` env scrubbing — prefer it over the env var)
#   WG_SERVER_IP           (default 10.99.0.1/24)
#   WG_CLIENT_IP           (default 10.99.0.2/32)
#   WG_PORT                WireGuard listen port (default 51820)
#   BRIDGE_PORT            bridge port to relay (default 11436)
#   VPC_RANGE              source range allowed to use the DNAT (default 10.42.0.0/24)
#
# Idempotent: safe to re-run (keeps existing keys; always reloads conf).

set -euo pipefail

WG_CLIENT_PUBKEY="${1:-${WG_CLIENT_PUBKEY:-}}"
WG_SERVER_IP="${WG_SERVER_IP:-10.99.0.1/24}"
WG_CLIENT_IP="${WG_CLIENT_IP:-10.99.0.2/32}"
WG_PORT="${WG_PORT:-51820}"
BRIDGE_PORT="${BRIDGE_PORT:-11436}"
VPC_RANGE="${VPC_RANGE:-10.42.0.0/24}"
WG_DIR=/etc/wireguard

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo bash $0 [WG_CLIENT_PUBKEY])" >&2
  exit 1
fi

echo "=== [1/5] Installing wireguard + nftables ==="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard nftables >/dev/null

echo "=== [2/5] Server keypair ==="
mkdir -p "$WG_DIR"
if [ ! -f "$WG_DIR/privatekey" ]; then
  wg genkey > "$WG_DIR/privatekey"
  chmod 600 "$WG_DIR/privatekey"
  echo "Generated new keypair"
fi
SERVER_PRIVKEY="$(cat "$WG_DIR/privatekey")"
SERVER_PUBKEY="$(echo "$SERVER_PRIVKEY" | wg pubkey)"

echo "=== [3/5] Writing $WG_DIR/wg0.conf ==="
{
  cat <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
EOF
  if [ -n "$WG_CLIENT_PUBKEY" ]; then
    cat <<EOF

[Peer]
PublicKey = ${WG_CLIENT_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}
PersistentKeepalive = 25
EOF
  else
    echo ""
    echo "# No [Peer] yet — re-run with the TIALA client key:"
    echo "#   sudo bash setup-wireguard-bridgegw.sh <WG_CLIENT_PUBKEY>"
  fi
} > "$WG_DIR/wg0.conf"
chmod 600 "$WG_DIR/wg0.conf"
if [ -z "$WG_CLIENT_PUBKEY" ]; then
  echo "Bootstrap mode: peer-less config written (re-run with WG_CLIENT_PUBKEY to add TIALA)"
fi

echo "=== [4/5] IP forwarding + DNAT :${BRIDGE_PORT} -> TIALA ==="
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-magi-forward.conf
# Dedicated 'magi' table only — 'destroy' replaces our table and never touches
# pre-existing rules. DNAT is restricted to VPC sources so the external IP
# cannot be used to reach the bridge API.
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
destroy table ip magi
table ip magi {
    chain prerouting {
        type nat hook prerouting priority dstnat;
        ip saddr ${VPC_RANGE} tcp dport ${BRIDGE_PORT} dnat to ${WG_CLIENT_IP%/*}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat;
        ip daddr ${WG_CLIENT_IP%/*} masquerade
    }
}
EOF
systemctl enable nftables >/dev/null 2>&1 || true
nft -f /etc/nftables.conf

echo "=== [5/5] Enable + verify ==="
systemctl enable wg-quick@wg0 >/dev/null 2>&1
# restart (not enable --now): reloads wg0.conf on re-runs such as registering
# the client key after bootstrap.
systemctl restart wg-quick@wg0
sleep 2
wg show wg0 || true

echo ""
echo ">>> GIVE THIS TO THE TIALA SETUP (WG_SERVER_PUBKEY) <<<"
echo "WG_SERVER_PUBKEY=${SERVER_PUBKEY}"
echo ""
if wg show wg0 latest-handshakes | awk '{print $2}' | grep -qv '^0$'; then
  echo "OK: handshake with TIALA established"
  # Reach the bridge through the tunnel directly — a request to the VM's own
  # VPC address takes the OUTPUT path and never traverses prerouting DNAT.
  curl -fsS -m 5 "http://${WG_CLIENT_IP%/*}:${BRIDGE_PORT}/health" \
    && echo "OK: bridge reachable through the tunnel" \
    || echo "NOTE: tunnel curl failed — check bridge on TIALA + macOS firewall"
else
  echo "NOTE: no handshake yet — bring TIALA's tunnel up (setup-wireguard-tiala.sh)"
fi
