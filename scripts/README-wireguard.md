# WireGuard private route — TIALA side handoff (P3)

Part of the magi-moomoo#66 private-connectivity migration. This is the
TIALA-side (macOS) work package; it can be handed to a Devin CLI session on
TIALA over SSH.

## Prerequisites (from Jun, after P2)

- `bridge-gw` VM exists in `magi-vpc` (10.42.0.10, asia-northeast1-a) with a
  static external IP and `udp:51820` open (`magi-allow-wg` firewall rule).
- The VM setup script has been run there
  (`scripts/setup-wireguard-bridgegw.sh`), which prints `WG_SERVER_PUBKEY`.
- Jun provides: `WG_SERVER_ENDPOINT` (`<bridge-gw external IP>:51820`) and
  `WG_SERVER_PUBKEY`.

## Task for the TIALA Devin CLI session

```bash
cd ~/magi-moomoo   # TIALA clone (adjust WorkingDirectory if different)
git fetch origin && git checkout <branch-with-these-scripts>
WG_SERVER_ENDPOINT=<bridge-gw external IP>:51820 \
WG_SERVER_PUBKEY=<server pubkey> \
bash scripts/setup-wireguard-tiala.sh
```

The script is idempotent and does not touch the Cloudflare tunnel —
`cloudflared` / `start-bridge.sh` keep running as the fallback route.

Report back:

- `WG_CLIENT_PUBKEY` — must be registered on bridge-gw's `wg0.conf [Peer]`
  (Jun or the VM-side agent adds it and re-runs the VM script / `wg syncconf`).
- Output of `sudo wg show wg0` and `ping 10.99.0.1`.

## Verify end-to-end (from bridge-gw, Jun side)

```bash
gcloud compute ssh bridge-gw --zone=asia-northeast1-a \
  --command='curl -fsS -m 5 http://10.42.0.10:11436/health && wg show wg0 latest-handshakes'
```

`/health` is the only bridge endpoint exempt from `BRIDGE_AUTH_TOKEN`, so this
proves TIALA reachability without exposing a token on the VM.

## Gotchas

- macOS needs **both** `wireguard-tools` and `wireguard-go` (userspace impl;
  wg-quick calls it). The App Store WireGuard app is NOT used.
- `moomoo_bridge.py` already binds `0.0.0.0:11436` — accepts the WG interface
  with no code change.
- macOS Application Firewall may prompt for inbound python on first tunnel
  connection — approve "allow" if it appears.
- Keepalive (25s) keeps NAT state open; TIALA needs no inbound port forwarding.

## Rollback

```bash
sudo wg-quick down wg0
launchctl unload ~/Library/LaunchAgents/com.magi.wireguard.plist
rm ~/Library/LaunchAgents/com.magi.wireguard.plist
```

Cloudflare route is unaffected; proxy falls back automatically in `auto` mode.
