# Monitoring Stack Migration: Uptime Kuma → Prometheus + Grafana

## Why Switch

Uptime Kuma was chosen for its simple UI, but it is fundamentally the wrong tool for this setup:

- Cannot be configured programmatically — every monitor requires clicking through a web UI
- The Python API library (`uptime-kuma-api`) is frozen at Kuma 1.x and broke on 2.x
- Push monitors are primitive: a single up/down flag with optional ping, no labels or dimensions
- No way to expose VPS resource metrics (CPU, RAM, bandwidth) without a separate tool anyway
- Dashboard templating is non-existent — adding a new EU mirror requires manually duplicating panels

Prometheus + Grafana gives API-first, code-driven monitoring that matches how the rest of this repo works.

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Central Node (RU VPS — reuses existing host)                   │
│                                                                 │
│  Prometheus :9090   ── scrapes ──► Node Exporter (RU) :9100    │
│      │                        ──► Node Exporter (EU) :9100     │
│      │                        ──► Blackbox Exporter (RU) :9115 │
│      │               ◄── push ── Pushgateway :9091             │
│  Grafana :3000      ── queries ► Prometheus                     │
│  Pushgateway :9091  ◄── curl  ── tls-push-monitor (RU + EU)    │
└─────────────────────────────────────────────────────────────────┘

┌──────────────────────────────┐
│  EU Exit VPS                 │
│  Node Exporter :9100         │
│  tls-push-monitor (baseline) │
│    └─► POSTs to Pushgateway  │
└──────────────────────────────┘
```

All Prometheus, Grafana, and Pushgateway run on the **RU node** — same host Kuma used. No extra VPS needed.

Blackbox Exporter also runs on the RU node and probes EU ports from Russian IP space, which is exactly what the DPI monitors need.

---

## Component Mapping

### 1. TCP Monitors — Blackbox Exporter (RU node)

Replaces the 6 Kuma TCP monitors. Blackbox is configured with a `tcp_connect` module. Prometheus scrapes it with a `relabel_configs` block that passes each target as a parameter — no UI interaction, all YAML.

**Targets configured in `prometheus.yml`:**
```yaml
- job_name: tcp_probes
  metrics_path: /probe
  params:
    module: [tcp_connect]
  static_configs:
    - targets:
        - 127.0.0.1:443        # Xray Local
        - 127.0.0.1:48022      # SSH Local
        - <EU_IP>:443          # EU Xray
        - <EU_IP>:8443
        - <EU_IP>:9443
        - <EU_IP>:48022        # EU SSH
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: 127.0.0.1:9115   # Blackbox Exporter address
```

Key metric: `probe_success` (1 = up, 0 = down), `probe_duration_seconds`.

### 2. TLS-Baseline & TLS-DPI Monitors — Pushgateway + tls-push-monitor.sh

Replaces the 6 Kuma push monitors. The existing `tls-push-monitor.sh` script needs only its push format changed — from Kuma's `?status=up&ping=<ms>` query string to a Prometheus metrics push.

**New push format (from tls-push-monitor.sh):**
```bash
# On success (SNI = debian.snt.utwente.nl, latency = 42ms, mode = baseline):
# Uses -D /dev/null to ensure robust parsing of connection time.
cat <<EOF | curl -s -D /dev/null -H "Content-Type: text/plain" --data-binary @- http://127.0.0.1:9091/metrics/job/tls_probes/instance/${INSTANCE}/sni/debian.snt.utwente.nl/mode/baseline
# TYPE tls_probe_success gauge
tls_probe_success 1
# TYPE tls_probe_latency_ms gauge
tls_probe_latency_ms 42
EOF
```

The `sni` and `mode` path segments become Prometheus labels automatically. The DPI truth matrix (EU-baseline UP + RU-DPI DOWN = block) becomes a simple PromQL alert rule.

### 2.1 SSL Certificate Monitoring
Blackbox Exporter is configured with an `http_2xx` module to monitor the Grafana SSL certificate.
```yaml
- job_name: cert_probes
  metrics_path: /probe
  params:
    module: [http_2xx]
  static_configs:
    - targets:
        - https://<KUMA_DOMAIN>:3000
```

---

## Alert Rules

Stored in `prometheus-alerts.yml`, loaded by Prometheus at startup. No UI configuration.

```yaml
groups:
  - name: vpn_alerts
    rules:
      - alert: DPIBlockDetected
        expr: tls_probe_success{mode="baseline"} == 1 and on(sni) tls_probe_success{mode="dpi"} == 0
        for: 2m

      - alert: TLSPushStale
        expr: time() - push_time_seconds{job="tls_probes"} > 120
        for: 2m
        annotations:
          summary: "DPI TLS push metrics stale on {{ $labels.instance }}"

      - alert: CertExpirySoon
        expr: (probe_ssl_earliest_cert_expiry - time()) / 3600 / 24 < 15
        for: 1h
```

Alerts route to Bark via Alertmanager + `bark-webhook.py`. Inhibit rules ensure that if a node is down (`NodeDown`), individual port alerts (`XrayPortDown`) for that instance are suppressed.

---

## Security & Reliability Notes

- **Certbot Renewal**: `setup-monitoring.sh` configures `certbot` with `--pre-hook` and `--post-hook` to automatically open and close UFW port 80 during renewal.
- **UFW Idempotency**: Setup scripts explicitly delete old rules before adding new ones to prevent rule accumulation on re-runs.
- **Service Security**: `tls-push-monitor.sh` silences source errors when running under the `nobody` user.

---

## Component Mapping (cont.)

### 3. VPS Resource Monitoring — Node Exporter

Replaces nothing (Kuma couldn't do this). Node Exporter runs on both VPS as a systemd service, exposing port 9100. Prometheus scrapes it every 15s.

Useful metrics out of the box:
- `node_cpu_seconds_total` — CPU usage
- `node_memory_MemAvailable_bytes` — RAM
- `node_network_transmit_bytes_total` / `node_network_receive_bytes_total` — bandwidth
- `node_filesystem_avail_bytes` — disk

### 4. Grafana Dashboard — Provisioned from JSON, No UI Clicks

Dashboard is committed to this repo as `grafana-dashboard.json` and mounted via file provisioning. On deploy, Grafana loads it automatically.

**Panel structure (single dashboard, template variables):**

Variable `$instance` — `label_values(node_cpu_seconds_total, instance)` — auto-discovers all nodes.
Variable `$sni` — `label_values(tls_probe_success, sni)` — auto-discovers all SNI targets.

Panels repeat over `$instance` and `$sni` — adding a new EU mirror requires only a Prometheus config line, not a single UI click.

**DPI Truth Matrix panel** — a Grafana table using:
```promql
label_join(tls_probe_success{mode="baseline"}, "pair", "/", "sni")
```
vs
```promql
label_join(tls_probe_success{mode="dpi"}, "pair", "/", "sni")
```
Side-by-side per SNI with color thresholds: green (both up), red (baseline up + DPI down = block), yellow (both down = mirror failure).

---

## Files to Create / Modify

| File | Action | Purpose |
|---|---|---|
| `setup-monitoring.sh` | **Modify** | Installs Prometheus, Grafana, Pushgateway, Node Exporter, Blackbox Exporter on RU node |
| `setup-node-exporter.sh` | **Modify** | Installs Node Exporter on EU node (lightweight, called from `setup-eu-exit.sh`) |
| `prometheus.yml` | **Modify** | Prometheus scrape config — all targets, relabeling, alert rule file path |
| `prometheus-alerts.yml` | **Modify** | Alert rules (DPI block, port down, disk low, stale push, cert expiry) |
| `grafana-dashboard.json` | **Create** | Provisioned dashboard JSON |
| `grafana-provisioning/` | **Create** | Grafana datasource + dashboard provisioning YAML |
| `tls-push-monitor.sh` | **Modify** | TLS handshake telemetry → Prometheus Pushgateway |
| `setup-eu-exit.sh` | **Modify** | Calls `setup-node-exporter.sh` |
| `setup-ru-bridge.sh` | **Modify** | Calls `setup-monitoring.sh` |

---

## Deployment Order

Same as before — scripts run on the remote VPS from inside the cloned repo:

1. `setup-vps.sh` on each VPS (unchanged)
2. `setup-eu-exit.sh` on EU VPS — installs Xray + Node Exporter + tls-push-monitor (baseline mode)
3. `setup-ru-bridge.sh` on RU VPS — installs Xray + full monitoring stack + tls-push-monitor (DPI mode)

The monitoring stack (`setup-monitoring.sh`) is called internally by `setup-ru-bridge.sh`, same pattern as before.

---

## Security Notes

- Prometheus, Pushgateway, and Grafana bind to `127.0.0.1` only
- Grafana is exposed publicly via nginx HTTPS on port 3000 (same Let's Encrypt cert pattern as Kuma used)
- Pushgateway is reachable from EU node over the public internet — firewall to allow only EU VPS IP on port 9091, or tunnel over SSH
- Node Exporter on EU node: firewall to allow only RU VPS IP on port 9100
- No Pushgateway Basic Auth needed if firewall-whitelisted; add it if EU IP is dynamic

---

## What Gets Removed

- `install-uptime-kuma.sh` — entire file deleted
- `configure-kuma.py` — entire file deleted
- All Kuma-specific cleanup in `setup-ru-bridge.sh` wipe block (`uptime-kuma`, `log-capture-webhook` service stops/removes)
- `log-capture-webhook.py` and `log-capture-webhook.service` — replaced by Alertmanager webhook receiver (`bark-webhook.py`)


