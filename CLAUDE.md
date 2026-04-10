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
2. **`setup-eu-exit.sh`** — Run on EU VPS. Installs Xray with 3 VLESS+Reality+XHTTP inbounds on ports 443/8443/9443 (one per SNI, matched dest). Prints UUID, Public Key, and Short ID — **copy these**. Also installs Node Exporter and tls-push-monitor (baseline mode).
3. **`setup-ru-bridge.sh`** — Run on RU VPS. Prompts for EU credentials from step 2. Sets up VLESS+Reality+Vision inbound with 3 outbound SNI targets on ports 443/8443/9443 load-balanced via `leastPing`. Calls `setup-monitoring.sh` internally.

## Key Scripts

| Script | Where to run | Purpose |
|---|---|---|
| `add-user.sh <name>` | RU Bridge | Add a user to Xray config, prints their VLESS link |
| `revoke-user.sh <name>` | RU Bridge | Remove user and mark link as revoked in `/usr/local/etc/xray/user_links.txt` |
| `setup-monitoring.sh` | RU VPS only | Installs Prometheus, Grafana, Pushgateway, Blackbox Exporter, Node Exporter, Alertmanager, Bark webhook bridge |
| `setup-node-exporter.sh` | EU VPS only | Installs Node Exporter (called by setup-eu-exit.sh) |
| `tls-push-monitor.sh` | Both VPS (systemd) | TLS handshake telemetry → Prometheus Pushgateway (every 30 seconds) |

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
**Monitor env file**: `/etc/xray-monitor.env` (mode 600 — contains Pushgateway URL, TLS mode, peer IPs)

## Monitoring Stack (Prometheus + Grafana)

**Architecture**: All monitoring runs on the RU node. EU node pushes metrics to the RU Pushgateway. Grafana exposes the dashboard publicly over HTTPS.

```
RU Node:
  Prometheus :9090  ← scrapes → Blackbox Exporter :9115  (TCP probes)
                    ← scrapes → Pushgateway :9091          (TLS push metrics)
                    ← scrapes → Node Exporter :9100        (RU resources)
                    ← scrapes → Node Exporter (EU) :9100   (EU resources)
  Grafana :13000 (internal) → nginx HTTPS :3000 (public)
  Alertmanager :9093 → bark-webhook.py :9095 → Bark API

EU Node:
  Node Exporter :9100          (scraped by RU Prometheus)
  tls-push-monitor.service → POST → RU Pushgateway :9091
```

**Dashboard**: Grafana behind nginx HTTPS reverse proxy on port 3000 (Let's Encrypt SSL). Access at `https://<KUMA_DOMAIN>:3000`.

**Metrics collected:**

*TCP port probes (Blackbox Exporter — from RU node's perspective):*

| Target | Purpose |
|---|---|
| 127.0.0.1:443 | Xray local port |
| 127.0.0.1:48022 | SSH local |
| EU_IP:443 | EU Xray port 1 |
| EU_IP:8443 | EU Xray port 2 |
| EU_IP:9443 | EU Xray port 3 |
| EU_IP:48022 | EU SSH |

*TLS telemetry (Pushgateway — DPI-aware):*

| Metric | Labels | Pushed from | Purpose |
|---|---|---|---|
| `tls_probe_success` | sni, mode=baseline | EU tls-push-monitor | Mirror server TLS health |
| `tls_probe_latency_ms` | sni, mode=baseline | EU tls-push-monitor | Mirror server latency |
| `tls_probe_success` | sni, mode=dpi | RU tls-push-monitor | Cross-border DPI test |
| `tls_probe_latency_ms` | sni, mode=dpi | RU tls-push-monitor | DPI probe latency |

**Truth Matrix** — DPI detection logic (PromQL alert: `tls_probe_success{mode="baseline"} == 1 and on(sni) tls_probe_success{mode="dpi"} == 0`):

| EU Baseline | RU DPI Probe | Meaning | Action |
|---|---|---|---|
| UP (~20ms) | UP (~70ms) | Nominal | None |
| DOWN | DOWN | Mirror server failure | Wait or rotate |
| UP | DOWN | **DPI Block** | **Immediate rotation** |
| DOWN | UP | Impossible state | Check EU routing |

**tls-push-monitor.sh** (`tls-push-monitor.service`):
- Runs as a systemd service (while-true loop, 30-second sleep)
- Config from `/etc/xray-monitor.env`: `TLS_MODE`, `TLS_TARGETS`, `TLS_RESOLVE_TO`, `TLS_PUSHGATEWAY_URL`
- **Baseline mode (EU)**: `curl` to real mirror servers, captures `time_appconnect`, pushes to Pushgateway
- **DPI probe mode (RU)**: `curl --resolve` forces SNI to EU IP on specific port, pushes to Pushgateway
- Push format: Prometheus text exposition to `<PUSHGATEWAY_URL>/metrics/job/tls_probes/instance/<hostname>/sni/<sni>/mode/<mode>`

**Alert rules** (`prometheus-alerts.yml`):
- `DPIBlockDetected` — baseline UP + DPI DOWN for same SNI, for 2m → critical
- `XrayPortDown` — TCP probe failure for 2m → critical
- `VPSDiskLow` — disk below 10%, for 5m → warning
- `NodeDown` — Node Exporter unreachable for 2m → critical
- `TLSPushMissing` — no DPI push metrics in Pushgateway for 5m → warning

**Notifications**: Alertmanager → `bark-webhook.py` (port 9095) → Bark API push.

## SSH Access After Setup

```powershell
# Windows (from PowerShell)
ssh -p 48022 -i "$env:USERPROFILE\.ssh\vps_key" root@<IP>

# Grafana dashboard (open directly in browser)
# https://<KUMA_DOMAIN>:3000
```

## Editing the Xray Config

Always test before restarting:
```bash
sudo xray -test -c /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

`add-user.sh` and `revoke-user.sh` use `jq` to modify the config in-place, then restart Xray automatically.
