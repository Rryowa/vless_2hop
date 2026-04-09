# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Deploys a two-hop stealth proxy to bypass Russian internet censorship (TSPU/DPI). Traffic flows:

```
Client → RU Bridge VPS (port 443, VLESS+Reality+Vision+TCP) → EU Exit VPS (ports 443/8443/9443, VLESS+Reality+XHTTP)
```

Both nodes run Xray-core. All scripts must be executed **on the remote VPS** (not locally), and must be run **from inside the cloned repo directory** because scripts reference each other by relative path.

## Deployment Order

Run scripts in this sequence — later scripts depend on output from earlier ones:

1. **`setup-vps.sh <pubkey>`** — Run on each VPS first. Configures root key-only SSH on port 48022, enables UFW (ports 48022 + 443), installs fail2ban.
2. **`setup-eu-exit.sh`** — Run on EU VPS. Installs Xray with 3 VLESS+Reality+XHTTP inbounds on ports 443/8443/9443 (one per SNI, matched dest). Prints UUID, Public Key, and Short ID — **copy these**.
3. **`setup-ru-bridge.sh`** — Run on RU VPS. Prompts for EU credentials from step 2. Sets up VLESS+Reality+Vision inbound with 3 outbound SNI targets on ports 443/8443/9443 load-balanced via `leastPing`.
4. **`install-uptime-kuma.sh --kuma-host`** — Run on RU VPS. Full Kuma install + monitoring. Prints EU baseline env file.
5. **`install-uptime-kuma.sh --remote-push`** — Run on EU VPS. Lightweight: env file + tls-push-monitor only (no Kuma). Copy baseline env from step 4.

## Key Scripts

| Script | Where to run | Purpose |
|---|---|---|
| `add-user.sh <name>` | RU Bridge | Add a user to Xray config, prints their VLESS link |
| `revoke-user.sh <name>` | RU Bridge | Remove user and mark link as revoked in `/usr/local/etc/xray/user_links.txt` |
| `install-uptime-kuma.sh --kuma-host` | RU VPS only | Full Kuma + all monitoring infrastructure |
| `install-uptime-kuma.sh --remote-push` | EU VPS only | Lightweight: env file + tls-push-monitor only |
| `configure-kuma.py` | RU VPS only | Auto-configures all 12 monitors (6 TCP + 3 TLS-Baseline + 3 TLS-DPI) |
| `configure-kuma-peer.sh <eu_ip>` | RU VPS only | Adds EU TCP monitors to existing Kuma instance |
| `tls-push-monitor.sh` | Both VPS (systemd) | TLS handshake telemetry → Kuma push (every 30 seconds) |

## Architecture Details

**EU Exit Node** (`setup-eu-exit.sh`):
- 3 separate VLESS+Reality+XHTTP inbounds, each with matched `dest` and `serverNames`:
  - Port 443: `debian.snt.utwente.nl` → `debian.snt.utwente.nl:443`
  - Port 8443: `nl.archive.ubuntu.com` → `nl.archive.ubuntu.com:443`
  - Port 9443: `eclipse.mirror.liteserver.nl` → `eclipse.mirror.liteserver.nl:443`
- All 3 inbounds share the same UUID, private key, and short ID
- Path: `/unicorn-magic`, mode: `stream-one`, xPaddingBytes: `100-1000`
- Routing: blocks `geoip:ru` and `geosite:category-ru` via blackhole (prevents traffic loops)

**RU Bridge Node** (`setup-ru-bridge.sh`):
- VLESS+Reality+Vision inbound on port 443, SNI target: `vkvideo.ru`
- 3 parallel XHTTP outbounds to EU on ports 443/8443/9443, balanced by `burstObservatory` leastPing
- DNS set to Yandex (`77.88.8.8`, `77.88.8.1`) to resolve Russian domains correctly
- Same RU geoip/geosite blackhole rules as EU node

**Shared infrastructure** (both nodes):
- Runet routing databases (`geosite.dat`, `geoip.dat`) from `runetfreedom/russia-v2ray-rules-dat`, auto-updated weekly via cron (Sundays 3 AM)
- Xray systemd service configured with `Restart=always`, `RestartSec=5`
- Log rotation: daily, 3 rotations, max 50 MB, journal capped at 50 MB

**Config file location**: `/usr/local/etc/xray/config.json`
**Saved user links**: `/usr/local/etc/xray/user_links.txt`
**Kuma env file**: `/etc/xray-kuma.env` (mode 600 — contains push tokens, peer IPs)

## Monitoring Stack (Uptime Kuma)

**Single dashboard architecture**: Kuma runs on RU node only. Dashboard exposed publicly over HTTPS on `<KUMA_DOMAIN>:3001` via Let's Encrypt. EU pushes baseline TLS data remotely to RU over HTTPS.

**Dashboard**: Uptime Kuma behind nginx HTTPS reverse proxy on port 3001 (Let's Encrypt SSL). Nginx proxies to Kuma on port 13001. Access at `https://<KUMA_DOMAIN>:3001`.

**Monitors created by `configure-kuma.py`** (all on RU Kuma):

*Process liveness (native Kuma TCP monitors):*

| Monitor | Type | Target | Interval |
|---|---|---|---|
| Xray Local :443 | TCP | 127.0.0.1:443 | 60s |
| SSH Local :48022 | TCP | 127.0.0.1:48022 | 60s |
| EU Xray :443 | TCP | EU_IP:443 | 60s |
| EU Xray :8443 | TCP | EU_IP:8443 | 60s |
| EU Xray :9443 | TCP | EU_IP:9443 | 60s |
| EU SSH :48022 | TCP | EU_IP:48022 | 60s |

*TLS telemetry (push monitors — DPI-aware):*

| Monitor | Type | Pushed from | Purpose |
|---|---|---|---|
| TLS-Baseline debian.snt.utwente.nl | PUSH | EU tls-push-monitor.sh | Mirror server TLS health |
| TLS-Baseline nl.archive.ubuntu.com | PUSH | EU tls-push-monitor.sh | Mirror server TLS health |
| TLS-Baseline eclipse.mirror.liteserver.nl | PUSH | EU tls-push-monitor.sh | Mirror server TLS health |
| TLS-DPI debian.snt.utwente.nl | PUSH | RU tls-push-monitor.sh | Cross-border DPI test |
| TLS-DPI nl.archive.ubuntu.com | PUSH | RU tls-push-monitor.sh | Cross-border DPI test |
| TLS-DPI eclipse.mirror.liteserver.nl | PUSH | RU tls-push-monitor.sh | Cross-border DPI test |

**Truth Matrix** — side-by-side comparison per SNI:

| EU Baseline | RU DPI Probe | Meaning | Action |
|---|---|---|---|
| UP (~20ms) | UP (~70ms) | Nominal | None |
| DOWN | DOWN | Mirror server failure | Wait or rotate |
| UP | DOWN | **DPI Block** | **Immediate rotation** |
| DOWN | UP | Impossible state | Check EU routing |

**tls-push-monitor.sh** (`tls-push-monitor.service`):
- Runs as a systemd service with a 30-second sleep loop
- Mode auto-detected from env: `TLS_RESOLVE_TO` empty = baseline (EU), set = DPI probe (RU)
- **Baseline mode (EU)**: `curl` to real mirror servers on port 443, captures `time_appconnect`
- **DPI probe mode (RU)**: `curl --resolve` forces SNI to EU IP on specific port, captures `time_appconnect`
- Pushes `?status=up&ping=<ms>` (converted from seconds to milliseconds) or `?status=down&msg=<reason>`

**log-capture-webhook.py** (`log-capture-webhook.service`, port 9000):
- Receives Uptime Kuma webhook alerts
- On DOWN: captures last 50 lines of xray error/access logs, saves incident file, sends Bark follow-up
- On UP: saves recovery entry, sends Bark recovery push
- Incident retention: 30 days (cron purge at 4 AM daily)

**Notifications**: Bark push via Uptime Kuma native integration + webhook follow-ups with log context.

## SSH Access After Setup

```powershell
# Windows (from PowerShell)
ssh -p 48022 -i "$env:USERPROFILE\.ssh\vps_key" root@<IP>

# Kuma dashboard (open directly in browser)
# https://<KUMA_DOMAIN>:3001
```

## Editing the Xray Config

Always test before restarting:
```bash
sudo xray -test -c /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

`add-user.sh` and `revoke-user.sh` use `jq` to modify the config in-place, then restart Xray automatically.
