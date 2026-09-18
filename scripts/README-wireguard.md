# WireGuard private route — TIALA side handoff (P3)

Part of the magi-moomoo#66 private-connectivity migration. This is the
TIALA-side (macOS) work package; it can be handed to a Devin CLI session on
TIALA over SSH.

## Bootstrap order (avoids the key-exchange deadlock)

Neither side needs the other's key to *start*:

1. **bridge-gw first, no args** — `sudo bash setup-wireguard-bridgegw.sh`
   generates the server keypair, writes a peer-less `wg0.conf`, and prints
   `WG_SERVER_PUBKEY`.
2. **TIALA** — run the client script with `WG_SERVER_ENDPOINT` +
   `WG_SERVER_PUBKEY`; it prints `WG_CLIENT_PUBKEY`.
3. **bridge-gw again** — `sudo bash setup-wireguard-bridgegw.sh
   <WG_CLIENT_PUBKEY>` adds the `[Peer]` and reloads the live interface.

## Prerequisites (from Jun, after P2)

- `bridge-gw` VM exists in `magi-vpc` (10.42.0.10, asia-northeast1-a) with a
  static external IP, `can-ip-forward` enabled on the instance, and
  `udp:51820` open (`magi-allow-wg` firewall rule).
- A VPC **ingress** rule allows `tcp:11436` to the VM — this is the relayed
  bridge port VPC peers will hit; it is separate from the WireGuard rule.
- Step 1 above done on the VM → Jun provides `WG_SERVER_ENDPOINT`
  (`<bridge-gw external IP>:51820`) and `WG_SERVER_PUBKEY`.

## Task for the TIALA Devin CLI session

```bash
cd ~/magi-moomoo   # TIALA clone (adjust WorkingDirectory if different)
git fetch origin && git checkout main && git pull
WG_SERVER_ENDPOINT=<bridge-gw external IP>:51820 \
WG_SERVER_PUBKEY=<server pubkey> \
bash scripts/setup-wireguard-tiala.sh
```

The script is idempotent and does not touch the Cloudflare tunnel —
`cloudflared` / `start-bridge.sh` keep running as the fallback route.

Report back:

- `WG_CLIENT_PUBKEY` — Jun registers it on bridge-gw (step 3 above).
- Output of `sudo wg show wg0` and `ping -c2 -W 2500 10.99.0.1`.

## Verify end-to-end (from bridge-gw, Jun side)

```bash
gcloud compute ssh bridge-gw --zone=asia-northeast1-a \
  --command='curl -fsS -m 5 http://10.99.0.2:11436/health && wg show wg0 latest-handshakes'
```

Note: test the tunnel address `10.99.0.2`, **not** `10.42.0.10` — a locally
generated request to the VM's own address takes the OUTPUT path and never
traverses the prerouting DNAT rule.

`/health` is the only bridge endpoint exempt from `BRIDGE_AUTH_TOKEN`, so this
proves TIALA reachability without exposing a token on the VM.

## Gotchas

- macOS needs **both** `wireguard-tools` and `wireguard-go` (userspace impl;
  wg-quick calls it). The App Store WireGuard app is NOT used.
- Autostart uses a **LaunchDaemon** (`/Library/LaunchDaemons/`) — `wg-quick`
  needs root for the utun interface, so a user LaunchAgent cannot persist it.
- `moomoo_bridge.py` already binds `0.0.0.0:11436` — accepts the WG interface
  with no code change.
- macOS Application Firewall may prompt for inbound python on first tunnel
  connection — approve "allow" if it appears.
- Keepalive (25s) keeps NAT state open; TIALA needs no inbound port forwarding.

## Rollback

```bash
sudo wg-quick down "$(brew --prefix)/etc/wireguard/wg0.conf"
sudo launchctl unload /Library/LaunchDaemons/com.magi.wireguard.plist
sudo rm /Library/LaunchDaemons/com.magi.wireguard.plist
```

Cloudflare route is unaffected; proxy falls back automatically in `auto` mode.
