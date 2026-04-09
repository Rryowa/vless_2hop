# Multi-Hop Stealth Tunnel — Deployment Plan

## Architecture

```
Client → RU Bridge VPS (:443, VLESS+Reality+Vision+TCP, SNI: vkvideo.ru)
       → EU Exit VPS (:443/:8443/:9443, VLESS+Reality+XHTTP, load-balanced via leastPing)
       → Internet
```

Each EU inbound has a matched `dest`/`serverNames` pair — no protocol mismatch if DPI probes a specific SNI. All 3 inbounds share the same UUID, private key, and short ID.

| EU Port | SNI (`serverNames`) | Reality `dest` |
|---------|---------------------|-----------------|
| 443 | `debian.snt.utwente.nl` | `debian.snt.utwente.nl:443` |
| 8443 | `nl.archive.ubuntu.com` | `nl.archive.ubuntu.com:443` |
| 9443 | `eclipse.mirror.liteserver.nl` | `eclipse.mirror.liteserver.nl:443` |

SNI variables are defined at the top of each setup script. To rotate, edit `SNI_1`/`SNI_2`/`SNI_3`/`PORT_1`/`PORT_2`/`PORT_3` — everything downstream (Xray config, env files, monitoring, share links) derives from them.

## Monitoring: Single Dashboard, DPI-Aware

Kuma runs **only on RU**. Dashboard exposed via public HTTPS on `https://<KUMA_DOMAIN>:3001` with Let's Encrypt. EU pushes baseline TLS data remotely over HTTPS.

**Why not ICMP/HTTP/DNS monitors?** DPI blocks TLS, not ICMP. fping shows 100% uptime while the proxy is blackholed. HTTPS monitors test someone else's server. DNS monitors test domains you don't control. The only test that matters: TLS handshake time from behind the firewall.

**Truth Matrix** (side-by-side on one dashboard):

| EU Baseline | RU DPI Probe | Meaning | Action |
|---|---|---|---|
| UP (~20ms) | UP (~70ms) | Nominal | None |
| DOWN | DOWN | Mirror offline | Wait or rotate |
| UP | DOWN | **DPI Block** | **Immediate SNI rotation** |
| DOWN | UP | Impossible | Check EU routing |

**12 monitors total:**

| Monitor | Type | Target |
|---|---|---|
| Xray Local :443 | TCP | 127.0.0.1:443 |
| SSH Local :48022 | TCP | 127.0.0.1:48022 |
| EU Xray :443 | TCP | EU_IP:443 |
| EU Xray :8443 | TCP | EU_IP:8443 |
| EU Xray :9443 | TCP | EU_IP:9443 |
| EU SSH :48022 | TCP | EU_IP:48022 |
| TLS-Baseline \<sni\> x3 | PUSH | EU tls-push-monitor (mirror health) |
| TLS-DPI \<sni\> x3 | PUSH | RU tls-push-monitor (cross-border DPI test) |

`tls-push-monitor.sh` runs on both nodes (30s loop). Mode auto-detected:
- **EU (baseline):** `curl` to real mirrors on port 443, captures `time_appconnect`
- **RU (DPI probe):** `curl --resolve` forces SNI to EU IP on correct port, captures `time_appconnect`

---

# Phase 0: Windows Preparation

## Generate SSH Key
```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\vps_key"
icacls "$env:USERPROFILE\.ssh\vps_key" /inheritance:r
icacls "$env:USERPROFILE\.ssh\vps_key" /grant:r "$($env:USERNAME):F"
```

## Upload Key & Clone Repo (run for BOTH EU_IP and RU_IP)

### On the VPS (SSH in as root with password):
```powershell
ssh root@<IP>
```

```sh
apt update && apt upgrade -y
apt install git -y
git clone https://github.com/Rryowa/vless_2hop.git && cd vless_2hop
bash setup-vps.sh
# When prompted, paste your public key (contents of vps_key.pub)
```

### Reconnect on port 48022:
```powershell
ssh -p 48022 -i "$env:USERPROFILE\.ssh\vps_key" root@<IP>
```

### SSH timeout / zombie fix (if needed):
```sh
sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config
sshd -t && systemctl restart ssh
```

### If locked out by fail2ban:
```sh
fail2ban-client unban <your_ip>
```

---

# Phase 1: EU Exit Node

```powershell
ssh -p 48022 -i "$env:USERPROFILE\.ssh\vps_key" root@<EU_IP>
```

```sh
cd vless_2hop
sudo bash setup-eu-exit.sh
```

**Prompts:** BARK_KEY (optional), RU Bridge IP (optional for now), Kuma dashboard domain.

**What it does:**
- Installs Xray with 3 VLESS+Reality+XHTTP inbounds (443/8443/9443)
- Opens UFW ports 8443 + 9443
- Generates UUID, public key, short ID
- Prints share link (EU-EXIT-FALLBACK)
- Installs lightweight TLS monitoring (`tls-push-monitor.sh` in baseline mode, pushes to RU)

**Copy these values for Phase 2:**
- EU UUID
- EU Public Key
- EU Short ID

---

# Phase 2: RU Bridge Node

```powershell
ssh -p 48022 -i "$env:USERPROFILE\.ssh\vps_key" root@<RU_IP>
```

```sh
cd vless_2hop
sudo bash setup-ru-bridge.sh
```

**Prompts:** EU IP, EU UUID, EU Public Key, EU Short ID, BARK_KEY, Kuma dashboard domain.

**What it does:**
- Installs Xray with VLESS+Reality+Vision inbound (SNI: vkvideo.ru)
- 3 XHTTP outbounds to EU on ports 443/8443/9443, load-balanced via `leastPing`
- Prints share link (RU-BRIDGE-PRIMARY)
- Installs full monitoring stack:
  - Uptime Kuma on `127.0.0.1:13001` (nginx proxies HTTPS on port 3001 with Let's Encrypt)
  - `configure-kuma.py` creates all 12 monitors automatically
  - `tls-push-monitor.sh` in DPI probe mode
  - `log-capture-webhook.py` for incident log capture
- **Prints the EU baseline env file** — copy this to the EU node

---

# Phase 3: Copy EU Env File

The RU setup prints an EU baseline env file at the end. Copy its contents to the EU node:

```sh
# On EU node:
sudo nano /etc/xray-kuma.env
# Paste the contents, save
sudo systemctl restart tls-push-monitor
```

---

# Phase 4: Dashboard Access

Open `https://<KUMA_DOMAIN>:3001` in your browser. All 12 monitors on one screen.

**Prerequisite:** DNS for `<KUMA_DOMAIN>` must point to RU VPS IP before running the RU setup (certbot verifies domain ownership).

---

# Phase 5: User Management

### Add a user:
```sh
sudo bash add-user.sh <name>
```
Prints a VLESS link for the user.

### Revoke a user:
```sh
sudo bash revoke-user.sh <name>
```

---

# Maintenance & Troubleshooting

## Check Xray Status
```sh
sudo systemctl status xray
```

## View Logs
```sh
sudo tail -f /var/log/xray/error.log
sudo journalctl -u xray -f
sudo tail -f /var/log/xray/access.log
```

## Test Config Before Restart
```sh
sudo xray -test -c /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

## Force-Update Russian Routing Lists
```sh
sudo curl -sL -o /usr/local/share/xray/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
sudo curl -sL -o /usr/local/share/xray/geoip.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat
sudo systemctl restart xray
```

## Add EU Peer Monitors Later (if skipped)
```sh
sudo bash configure-kuma-peer.sh <EU_IP>
```

## Incident Logs
Captured automatically by `log-capture-webhook.py` on alerts. Stored in `/var/log/xray/incidents/`, auto-purged after 30 days.

---

# Key File Locations

| File | Location |
|---|---|
| Xray config | `/usr/local/etc/xray/config.json` |
| User links | `/usr/local/etc/xray/user_links.txt` |
| Kuma env file | `/etc/xray-kuma.env` (mode 600) |
| EU baseline env | `/tmp/xray-kuma-env-eu-baseline` (on RU node) |
| Xray logs | `/var/log/xray/access.log`, `/var/log/xray/error.log` |
| Incident logs | `/var/log/xray/incidents/` |
