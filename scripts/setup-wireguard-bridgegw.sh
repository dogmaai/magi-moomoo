#!/bin/bash
# setup-wireguard-bridgegw.sh — WireGuard server + TCP relay on the bridge-gw
# GCE VM (Debian 12, magi-vpc 10.42.0.10) for magi-moomoo#66 phase P3.
#
# Run ON the bridge-gw VM (after Jun creates it per the plan comment):
#   gcloud compute ssh bridge-gw --zone=asia-northeast1-a
#   WG_CLIENT_PUBKEY=<from TIALA setup output> sudo bash setup-wireguard-bridgegw.sh
#
# What it does:
#   1. apt install wireguard nftables
#   2. Generate server keypair (if absent); print WG_SERVER_PUBKEY for TIALA
#   3. Write /etc/wireguard/wg0.conf  (server 10.99.0.1, peer = TIALA 10.99.0.2)
#   4. Enable IP forwarding + DNAT  tcp/11436 -> 10.99.0.2:11436
#   5. systemctl enable --now wg-quick@wg0; verify handshake
#
# magi-moomoo then reaches the bridge as http://10.42.0.10:11436 — the DNAT
# makes the VM's VPC address the fixed private endpoint.
#
# Env vars:
#   WG_CLIENT_PUBKEY   (required) TIALA's client public key
#   WG_SERVER_IP       (default 10.99.0.1/24)
#   WG_CLIENT_IP       (default 10.99.0.2/32)
#   WG_PORT            WireGuard listen port (default 51820)
#   BRIDGE_PORT        bridge port to relay (default 11436)
#
# Idempotent: safe to re-run (regenerates conf, keeps existing keys).

set -euo pipefail

WG_SERVER_IP="${WG_SERVER_IP:-10.99.0.1/24}"
WG_CLIENT_IP="${WG_CLIENT_IP:-10.99.0.2/32}"
WG_PORT="${WG_PORT:-51820}"
BRIDGE_PORT="${BRIDGE_PORT:-11436}"
WG_DIR=/etc/wireguard

if [ -z "${WG_CLIENT_PUBKEY:-}" ]; then
  echo "ERROR: WG_CLIENT_PUBKEY is required (from TIALA setup output)." >&2
  echo "  WG_CLIENT_PUBKEY=xxxx sudo bash $0" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
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
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${WG_CLIENT_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}
PersistentKeepalive = 25
EOF
chmod 600 "$WG_DIR/wg0.conf"

echo "=== [4/5] IP forwarding + DNAT :${BRIDGE_PORT} -> TIALA ==="
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-magi-forward.conf
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table ip magi {
    chain prerouting {
        type nat hook prerouting priority dstnat;
        tcp dport ${BRIDGE_PORT} dnat to ${WG_CLIENT_IP%/*}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat;
        ip daddr ${WG_CLIENT_IP%/*} masquerade
    }
}
EOF
systemctl enable --now nftables >/dev/null 2>&1 || true
nft -f /etc/nftables.conf

echo "=== [5/5] Enable + verify ==="
systemctl enable --now wg-quick@wg0
sleep 2
wg show wg0 || true

echo ""
echo ">>> GIVE THIS TO THE TIALA SETUP (WG_SERVER_PUBKEY) <<<"
echo "WG_SERVER_PUBKEY=${SERVER_PUBKEY}"
echo ""
if wg show wg0 latest-handshakes | awk '{print $2}' | grep -qv '^0$'; then
  echo "OK: handshake with TIALA established"
  curl -fsS -m 5 "http://10.42.0.10:${BRIDGE_PORT}/health" \
    && echo "OK: bridge reachable through DNAT" \
    || echo "NOTE: DNAT curl failed — check bridge on TIALA + macOS firewall"
else
  echo "NOTE: no handshake yet — bring TIALA's tunnel up (setup-wireguard-tiala.sh)"
fi
