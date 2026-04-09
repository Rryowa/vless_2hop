#!/usr/bin/env python3
"""
Automates Uptime Kuma monitor creation via socket.io API.
Runs ONLY on the RU node (Kuma host). Creates all monitors for both nodes.

Usage:
  python3 configure-kuma.py <url> <username> <password> \
      --eu-ip <ip> \
      --eu-snis <host:port,...> \
      --ru-snis <host:port,...> \
      [--ru-ip <ip>] \
      [--env-file /etc/xray-kuma.env] \
      [--eu-env-file /tmp/xray-kuma-env-eu-baseline]

Creates:
  - TCP monitors for local (RU) + EU peer (multi-port: 443/8443/9443)
  - 3 TLS-Baseline PUSH monitors (EU pushes TLS health of real mirror servers)
  - 3 TLS-DPI PUSH monitors (RU pushes cross-border DPI probe results)
"""

import time
import json
import argparse
from uptime_kuma_api import UptimeKumaApi, MonitorType


def wait_for_kuma(url, timeout=60):
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            api = UptimeKumaApi(url, wait_events=0.5)
            return api
        except Exception as e:
            last_err = e
            time.sleep(3)
    raise RuntimeError(f"Kuma not ready after {timeout}s: {last_err}")


def add_if_new(api, existing, **kwargs):
    name = kwargs["name"]
    if name in existing:
        print(f"[Kuma] Monitor '{name}' already exists, skipping.")
        return None
    result = api.add_monitor(**kwargs)
    existing.add(name)
    print(f"[Kuma] Added: {name}")
    return result


def get_push_token(api, monitor_id):
    try:
        detail = api.get_monitor(monitor_id)
        return detail.get("pushToken") or detail.get("push_token", "")
    except Exception:
        return ""


def write_env_file(path, lines):
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    import os

    os.chmod(path, 0o600)
    print(f"[Kuma] Env file written to {path}")


def main():
    parser = argparse.ArgumentParser(description="Configure Uptime Kuma monitors")
    parser.add_argument("url")
    parser.add_argument("username")
    parser.add_argument("password")
    parser.add_argument("--eu-ip", required=True, help="EU VPS public IP")
    parser.add_argument(
        "--ru-ip", default="", help="RU VPS public IP (for EU env file)"
    )
    parser.add_argument(
        "--eu-snis",
        required=True,
        help="EU baseline targets: host:port,... (real mirror ports, all :443)",
    )
    parser.add_argument(
        "--ru-snis",
        required=True,
        help="RU DPI probe targets: host:port,... (EU Xray inbound ports: 443/8443/9443)",
    )
    parser.add_argument(
        "--ssh-port",
        type=int,
        default=48022,
        help="SSH management port (default: 48022)",
    )
    parser.add_argument(
        "--env-file",
        default="/etc/xray-kuma.env",
        help="RU env file to write DPI tokens into",
    )
    parser.add_argument(
        "--eu-env-file",
        default="/tmp/xray-kuma-env-eu-baseline",
        help="EU baseline env file to print/write",
    )
    parser.add_argument(
        "--local-sni",
        default="vkvideo.ru",
        help="This node's Reality SNI hostname (RU inbound SNI)",
    )
    parser.add_argument(
        "--peer-sni",
        default="debian.snt.utwente.nl",
        help="Peer's Reality SNI hostname (first EU inbound SNI)",
    )
    parser.add_argument(
        "--domain",
        default="",
        help="Domain name for Kuma dashboard (used in EU push URL)",
    )
    args = parser.parse_args()

    eu_snis = [s.strip() for s in args.eu_snis.split(",") if s.strip()]
    ru_snis = [s.strip() for s in args.ru_snis.split(",") if s.strip()]

    print("[Kuma] Connecting...")
    api = wait_for_kuma(args.url)

    with api:
        if api.need_setup():
            print("[Kuma] Creating admin account...")
            api.setup(args.username, args.password)
            print("[Kuma] Admin account created.")
        else:
            print("[Kuma] Admin already exists, skipping setup.")

        print("[Kuma] Logging in...")
        api.login(args.username, args.password)

        existing = {m["name"] for m in api.get_monitors()}

        baseline_tokens = {}
        dpi_tokens = {}

        add_if_new(
            api,
            existing,
            type=MonitorType.TCP,
            name="Xray Local :443",
            hostname="127.0.0.1",
            port=443,
            interval=60,
            maxretries=3,
        )

        add_if_new(
            api,
            existing,
            type=MonitorType.TCP,
            name=f"SSH Local :{args.ssh_port}",
            hostname="127.0.0.1",
            port=args.ssh_port,
            interval=60,
            maxretries=3,
        )

        add_if_new(
            api,
            existing,
            type=MonitorType.TCP,
            name="EU Xray :443",
            hostname=args.eu_ip,
            port=443,
            interval=60,
            maxretries=3,
        )

        add_if_new(
            api,
            existing,
            type=MonitorType.TCP,
            name="EU Xray :8443",
            hostname=args.eu_ip,
            port=8443,
            interval=60,
            maxretries=3,
        )

        add_if_new(
            api,
            existing,
            type=MonitorType.TCP,
            name="EU Xray :9443",
            hostname=args.eu_ip,
            port=9443,
            interval=60,
            maxretries=3,
        )

        add_if_new(
            api,
            existing,
            type=MonitorType.TCP,
            name=f"EU SSH :{args.ssh_port}",
            hostname=args.eu_ip,
            port=args.ssh_port,
            interval=60,
            maxretries=3,
        )

        PUSH_INTERVAL = 90

        for target in eu_snis:
            hostname = target.split(":")[0]
            name = f"TLS-Baseline {hostname}"
            if name not in existing:
                result = add_if_new(
                    api,
                    existing,
                    type=MonitorType.PUSH,
                    name=name,
                    interval=PUSH_INTERVAL,
                    maxretries=2,
                )
                if result:
                    mid = result.get("monitorID")
                    token = get_push_token(api, mid) if mid else ""
                    if token:
                        baseline_tokens[target] = token
            else:
                for m in api.get_monitors():
                    if m["name"] == name:
                        token = m.get("pushToken") or m.get("push_token", "")
                        if token:
                            baseline_tokens[target] = token
                        break

        for target in ru_snis:
            hostname = target.split(":")[0]
            name = f"TLS-DPI {hostname}"
            if name not in existing:
                result = add_if_new(
                    api,
                    existing,
                    type=MonitorType.PUSH,
                    name=name,
                    interval=PUSH_INTERVAL,
                    maxretries=2,
                )
                if result:
                    mid = result.get("monitorID")
                    token = get_push_token(api, mid) if mid else ""
                    if token:
                        dpi_tokens[target] = token
            else:
                for m in api.get_monitors():
                    if m["name"] == name:
                        token = m.get("pushToken") or m.get("push_token", "")
                        if token:
                            dpi_tokens[target] = token
                        break

        ru_env_lines = [
            f"PEER_IP={args.eu_ip}",
            f"PEER_SNI={args.peer_sni}",
            f"LOCAL_SNI={args.local_sni}",
            f"TLS_TARGETS={','.join(ru_snis)}",
            f"TLS_RESOLVE_TO={args.eu_ip}",
            f"KUMA_PUSH_URL=http://127.0.0.1:13001",
            f"TLS_PUSH_TOKENS='{json.dumps(dpi_tokens)}'",
        ]
        write_env_file(args.env_file, ru_env_lines)

        eu_env_lines = [
            f"PEER_IP={args.ru_ip}",
            f"PEER_SNI={args.local_sni}",
            f"LOCAL_SNI={args.peer_sni}",
            f"TLS_TARGETS={','.join(eu_snis)}",
            f"TLS_RESOLVE_TO=",
            f"KUMA_PUSH_URL=https://{args.domain}:3001"
            if args.domain
            else f"KUMA_PUSH_URL=http://{args.ru_ip}:3001",
            f"TLS_PUSH_TOKENS='{json.dumps(baseline_tokens)}'",
        ]
        write_env_file(args.eu_env_file, eu_env_lines)

    print("[Kuma] Configuration complete.")
    print("")
    print("=== EU BASELINE ENV FILE ===")
    print(f"Copy the contents of {args.eu_env_file} to EU node's /etc/xray-kuma.env:")
    print("")
    for line in eu_env_lines:
        print(f"  {line}")
    print("")


if __name__ == "__main__":
    main()
