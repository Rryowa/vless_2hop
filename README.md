# Multi-Hop Stealth Tunnel — VPN Stealth Proxy Stack

A two-hop stealth proxy designed to bypass advanced internet censorship (TSPU/DPI). Traffic flows through an RU Bridge node before exiting via an EU Exit node, utilizing VLESS+Reality with Vision (RU) and XHTTP (EU) protocols.

## Architecture

```
Client → RU Bridge VPS (:443, VLESS+Reality+Vision+TCP)
       → EU Exit VPS (:443/:8443/:9443, VLESS+Reality+XHTTP)
       → Internet
```

### Protocol Stack
- **Inbound (RU):** VLESS + Reality + Vision + TCP (SNI: `vkvideo.ru`)
- **Outbound (RU to EU):** VLESS + Reality + XHTTP (SNI: Multiple Dutch/German mirrors)
- **Monitoring:** Full Prometheus/Grafana stack on RU node with cross-border DPI telemetry.

---

## Prerequisites

1. Two VPS instances (one in RU, one in EU/US).
2. A domain name for the monitoring dashboard (e.g., `monitor.example.com`).
3. SSH key pair generated on your local machine.

---

## Deployment Instructions

### Phase 0: VPS Preparation (Run on BOTH VPS)

1. SSH into the VPS as root.
2. Clone the repository:
   ```bash
   apt update && apt install git -y
   git clone https://github.com/Rryowa/vless_2hop.git && cd vless_2hop
   ```
3. Run the hardening script:
   ```bash
   bash setup-vps.sh
   ```
   *Paste your SSH public key when prompted.*
4. **Reconnect on port 48022:** `ssh -p 48022 -i "$env:USERPROFILE\.ssh\vps_key" root@<IP>`

### Phase 1: EU Exit Node

1. On the **EU VPS**:
   ```bash
   cd vless_2hop
   sudo bash setup-eu-exit.sh
   ```
2. **Prompts:** Bark Key (optional), RU Bridge IP (optional for peer monitors).
3. **Save the output:** Copy the **EU UUID**, **EU Public Key**, and **EU Short ID**.

### Phase 2: RU Bridge Node

1. On the **RU VPS**:
   ```bash
   cd vless_2hop
   bash setup-ru-bridge.sh
   ```
2. **Prompts:** EU IP, EU UUID, EU Public Key, EU Short ID, Bark Key, Monitoring Domain.
3. **Dashboard Access:** DNS for your monitoring domain must point to the RU VPS IP. Access the dashboard at `https://<DOMAIN>:3000`.

---

## Monitoring Architecture

The stack runs entirely on the RU node, while the EU node pushes TLS health metrics.

```
┌─────────────────────────────────────────────────────────────────┐
│  Central Node (RU VPS)                                          │
│                                                                 │
│  Prometheus :9090   ── scrapes ──► Node Exporter (RU) :9100    │
│      │                        ──► Node Exporter (EU) :9100     │
│      │                        ──► Blackbox Exporter (RU) :9115 │
│      │               ◄── push ── Pushgateway :9091             │
│  Grafana :3000      ── queries ► Prometheus                     │
│  Pushgateway :9091  ◄── curl  ── tls-push-monitor (RU + EU)    │
└─────────────────────────────────────────────────────────────────┘
```

### DPI Truth Matrix (Detection Logic)

| EU Baseline | RU DPI Probe | Meaning | Action |
|---|---|---|---|
| UP | UP | Nominal | None |
| DOWN | DOWN | Mirror server failure | Wait or rotate |
| UP | DOWN | **DPI Block** | **Immediate SNI rotation** |
| DOWN | UP | Impossible state | Check EU routing |

---

## User Management

### Add a User
```bash
sudo bash add-user.sh <name>
```
*Prints a VLESS share link for the user.*

### Revoke a User
```bash
sudo bash revoke-user.sh <name>
```
*Removes the user and marks the link as revoked in `user_links.txt`.*

---

## Maintenance & Logs

- **Xray Config:** `/usr/local/etc/xray/config.json`
- **User Links:** `/usr/local/etc/xray/user_links.txt`
- **Test Config:** `sudo xray -test -c /usr/local/etc/xray/config.json`
- **Restart Xray:** `sudo systemctl restart xray`
- **View Logs:** `sudo tail -f /var/log/xray/access.log`
- **Update Routing Rules:** Done automatically weekly via cron.
