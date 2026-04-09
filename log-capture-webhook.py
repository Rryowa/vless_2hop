#!/usr/bin/env python3
"""
Uptime Kuma webhook receiver.
- On DOWN: captures last 50 lines of xray logs, saves incident file, sends Bark follow-up.
- On UP:   appends recovery entry, sends Bark recovery push.

Config is written by install-uptime-kuma.sh into the CONFIG block below.
"""

import http.server
import json
import os
import subprocess
import urllib.request
import urllib.parse
import datetime
import re
import time

# --- CONFIG (replaced by installer) ---
BARK_KEY = "BARK_KEY_PLACEHOLDER"
# --------------------------------------

INCIDENT_DIR = "/var/log/xray/incidents"
XRAY_ERROR_LOG = "/var/log/xray/error.log"
XRAY_ACCESS_LOG = "/var/log/xray/access.log"
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 9000


def bark_push(title, body):
    if not BARK_KEY or BARK_KEY == "BARK_KEY_PLACEHOLDER":
        return
    url = f"https://api.day.app/{urllib.parse.quote(BARK_KEY)}/{urllib.parse.quote(title)}/{urllib.parse.quote(body)}"
    try:
        urllib.request.urlopen(url, timeout=10)
    except Exception:
        pass


def tail_log(path, lines=50):
    try:
        result = subprocess.run(
            ["tail", "-n", str(lines), path], capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip()
    except Exception:
        return f"[could not read {path}]"


def safe_filename(name):
    return re.sub(r"[^a-zA-Z0-9._-]", "_", name)


def handle_alert(payload):
    os.makedirs(INCIDENT_DIR, exist_ok=True)
    monitor = payload.get("monitor", {})
    heartbeat = payload.get("heartbeat", {})
    monitor_name = monitor.get("name", "unknown")
    status = heartbeat.get("status", 1)  # 0=down, 1=up
    msg = heartbeat.get("msg", "")
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")
    fname = f"{ts}-{safe_filename(monitor_name)}.log"
    fpath = os.path.join(INCIDENT_DIR, fname)

    if status == 0:
        error_tail = tail_log(XRAY_ERROR_LOG)
        access_tail = tail_log(XRAY_ACCESS_LOG)
        content = (
            f"=== INCIDENT: {monitor_name} ===\n"
            f"Time:    {ts}\n"
            f"Message: {msg}\n\n"
            f"--- error.log (last 50) ---\n{error_tail}\n\n"
            f"--- access.log (last 50) ---\n{access_tail}\n"
        )
        with open(fpath, "w") as f:
            f.write(content)

        excerpt = error_tail[-1000:] if len(error_tail) > 1000 else error_tail
        bark_push(f"DOWN: {monitor_name}", excerpt or msg)

    else:
        with open(fpath, "w") as f:
            f.write(f"=== RECOVERY: {monitor_name} ===\nTime: {ts}\nMessage: {msg}\n")
        bark_push(f"UP: {monitor_name}", f"Recovered at {ts}")


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress access log noise

    def do_POST(self):
        if self.path != "/alert":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
            handle_alert(payload)
        except Exception:
            pass
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")


if __name__ == "__main__":
    # Purge incidents older than 30 days on startup
    if os.path.isdir(INCIDENT_DIR):
        cutoff = time.time() - 30 * 86400
        for fn in os.listdir(INCIDENT_DIR):
            fp = os.path.join(INCIDENT_DIR, fn)
            if os.path.isfile(fp) and os.path.getmtime(fp) < cutoff:
                os.remove(fp)

    server = http.server.HTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    server.serve_forever()
