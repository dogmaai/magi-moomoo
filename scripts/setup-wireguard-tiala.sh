#!/bin/bash
# setup-wireguard-tiala.sh — Install + configure the WireGuard client on TIALA
# for the magi-moomoo private bridge route (magi-moomoo#66, phase P3).
#
# What it does:
#   1. brew install wireguard-tools wireguard-go (wg-quick needs wireguard-go
#      as the macOS userspace implementation)
#   2. Generate a client keypair (if absent) into $WG_DIR
#   3. Write $WG_DIR/wg0.conf from the env vars below
#   4. Install /Library/LaunchDaemons/com.magi.wireguard.plist (RunAtLoad,
#      runs as root — wg-quick needs privileges for utun/routing)
#   5. Bring the tunnel up and verify handshake + gateway ping
#
# Run on TIALA:
#   WG_SERVER_ENDPOINT=203.0.113.10:51820 \
#   WG_SERVER_PUBKEY=<bridge-gw public key> \
#   bash scripts/setup-wireguard-tiala.sh
#
# Then hand the printed WG_CLIENT_PUBKEY to whoever configures bridge-gw —
# the VM's wg0.conf [Peer] section needs it before the tunnel can come up.
#
# Env vars (required):
#   WG_SERVER_ENDPOINT   bridge-gw external IP:port, e.g. 203.0.113.10:51820
#   WG_SERVER_PUBKEY     bridge-gw WireGuard server public key
# Env vars (optional):
#   WG_CLIENT_IP         client tunnel address (default 10.99.0.2/32)
#   WG_SERVER_IP         server tunnel address   (default 10.99.0.1)
#   WG_DIR               config dir (default /opt/homebrew/etc/wireguard,
#                        /usr/local/etc/wireguard on Intel brew). wg-quick is
#                        invoked with the explicit config path, so a custom
#                        WG_DIR works for both the script and the LaunchDaemon.
#
# Rollback:
#   sudo wg-quick down "$(brew --prefix)/etc/wireguard/wg0.conf"
#   sudo launchctl unload /Library/LaunchDaemons/com.magi.wireguard.plist
#   sudo rm /Library/LaunchDaemons/com.magi.wireguard.plist
# (Cloudflare tunnel path is untouched — keep it running until P8.)

set -euo pipefail

WG_CLIENT_IP="${WG_CLIENT_IP:-10.99.0.2/32}"
WG_SERVER_IP="${WG_SERVER_IP:-10.99.0.1}"
WG_PORT_HOST=11436   # bridge listens here (0.0.0.0 — WG interface needs no bind change)

# Ensure brew is in PATH (especially for non-interactive SSH sessions)
if ! command -v brew >/dev/null 2>&1; then
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$dir/brew" ]; then
      export PATH="$dir:$PATH"
      break
    fi
  done
fi

# brew prefix differs by arch: /opt/homebrew (Apple Silicon) / /usr/local (Intel)
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
WG_DIR="${WG_DIR:-${BREW_PREFIX}/etc/wireguard}"
PLIST_NAME="com.magi.wireguard.plist"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}"
LEGACY_AGENT_PLIST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"

if [ -z "${WG_SERVER_ENDPOINT:-}" ] || [ -z "${WG_SERVER_PUBKEY:-}" ]; then
  echo "ERROR: WG_SERVER_ENDPOINT and WG_SERVER_PUBKEY are required." >&2
  echo "Example:" >&2
  echo "  WG_SERVER_ENDPOINT=203.0.113.10:51820 WG_SERVER_PUBKEY=xxxx bash $0" >&2
  exit 1
fi

echo "=== [1/5] Installing wireguard-tools + wireguard-go ==="
for formula in wireguard-tools wireguard-go; do
  if ! brew list "$formula" >/dev/null 2>&1; then
    echo "Installing $formula..."
    brew install "$formula"
  fi
done

echo "=== [2/5] Generating client keypair (if absent) ==="
sudo mkdir -p "$WG_DIR"
if [ ! -f "$WG_DIR/privatekey" ]; then
  wg genkey | sudo tee "$WG_DIR/privatekey" >/dev/null
  sudo chmod 600 "$WG_DIR/privatekey"
  echo "Generated new keypair"
else
  echo "Reusing existing $WG_DIR/privatekey"
fi
CLIENT_PRIVKEY="$(sudo cat "$WG_DIR/privatekey")"
CLIENT_PUBKEY="$(echo "$CLIENT_PRIVKEY" | wg pubkey)"

echo "=== [3/5] Writing $WG_DIR/wg0.conf ==="
sudo tee "$WG_DIR/wg0.conf" >/dev/null <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${WG_CLIENT_IP}

[Peer]
PublicKey = ${WG_SERVER_PUBKEY}
Endpoint = ${WG_SERVER_ENDPOINT}
AllowedIPs = ${WG_SERVER_IP%/*}/32
PersistentKeepalive = 25
EOF
sudo chmod 600 "$WG_DIR/wg0.conf"
echo "Config written. Endpoint=${WG_SERVER_ENDPOINT} ClientIP=${WG_CLIENT_IP}"

echo "=== [4/5] Installing launchd daemon ${PLIST_NAME} ==="
# Clean up a legacy per-user LaunchAgent install if present — it can never
# bring the tunnel up (wg-quick needs root) and would just log failures.
launchctl unload "$LEGACY_AGENT_PLIST" 2>/dev/null || true
rm -f "$LEGACY_AGENT_PLIST"
# wg-quick needs root for utun/routing — a user LaunchAgent cannot do this.
# LaunchDaemons run with a minimal PATH, so include the brew prefix or wg /
# wireguard-go will not resolve.
sudo tee "$PLIST_PATH" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.magi.wireguard</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BREW_PREFIX}/bin/wg-quick</string>
        <string>up</string>
        <string>${WG_DIR}/wg0.conf</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/magi-wireguard.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/magi-wireguard.stderr.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"
sudo launchctl unload "$PLIST_PATH" 2>/dev/null || true
sudo launchctl load "$PLIST_PATH"
echo "Installed as LaunchDaemon (runs as root at boot; the utun interface persists)"

echo "=== [5/5] Bringing tunnel up + verification ==="
# Pass the config path explicitly: `wg-quick up wg0` would only search the
# default brew config dir and ignore a custom WG_DIR. The interface name is
# still derived from the basename (wg0), so `wg show wg0` keeps working.
sudo wg-quick down "${WG_DIR}/wg0.conf" 2>/dev/null || true
sudo wg-quick up "${WG_DIR}/wg0.conf"

echo ""
echo ">>> REGISTER THIS ON bridge-gw (wg0.conf [Peer] PublicKey) <<<"
echo "WG_CLIENT_PUBKEY=${CLIENT_PUBKEY}"
echo ""

sleep 3
if sudo wg show wg0 latest-handshakes | awk '{print $2}' | grep -qv '^0$'; then
  echo "OK: handshake established with bridge-gw"
else
  echo "NOTE: no handshake yet — expected until bridge-gw registers WG_CLIENT_PUBKEY"
fi

if ping -c2 -W 2500 "${WG_SERVER_IP%/*}" >/dev/null 2>&1; then
  echo "OK: ping ${WG_SERVER_IP%/*} (wireguard gateway)"
else
  echo "NOTE: ping ${WG_SERVER_IP%/*} failed — check server-side [Peer] config + firewall udp:51820"
fi

echo ""
echo "Next (server-side verified): bridge-gw should curl http://10.99.0.2:${WG_PORT_HOST}/health"
echo "to confirm moomoo-bridge is reachable over the tunnel."
