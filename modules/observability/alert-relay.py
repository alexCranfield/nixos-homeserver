#!/usr/bin/env python3
# Relay from Alertmanager's webhook to Discord, for ticket #27.
#
#   alert-relay.py SENDER WEBHOOK_FILE ROLE_FILE HOST PORT
#
# Serves HTTP (Hypertext Transfer Protocol) POST / on 127.0.0.1:PORT. Each
# alert in the body (Alertmanager's webhook format, version 4) becomes one call
# of
#
#   SENDER WEBHOOK_FILE (ROLE_FILE|-) ICON TITLE
#
# with the body on stdin: the homeserver-notify program of
# modules/base/notify.nix, which owns the webhook URL. This program never
# reads the URL, so it cannot leak it. ROLE_FILE is `-` for a resolved alert,
# which pings no one. No shell is involved: the text of an alert is data, only
# ever one argument or the standard input.
#
# Replies 200 if every post succeeded, else 500, and Alertmanager then retries
# the whole notification.
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIRING = "🔴"
RESOLVED = "✅"
# A hung sender must not hold the reply for ever. Alertmanager 0.31 puts no
# limit of its own on a webhook call unless the receiver sets `timeout`
# (modules/observability/alerting.nix sets 4 minutes); what bounds a
# notification otherwise is its context, max(group_interval, 10 s), about 5
# minutes here (10 s is only notify.MinTimeout, the lower bound). A post that
# outlives that is retried while this one still completes, so it double-posts:
# this limit must stay well under it, even for a request of several alerts.
SEND_TIMEOUT = 60


def parse_time(s):
    """RFC (Request for Comments) 3339 with up to nanoseconds, which datetime cannot read."""
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)", s)
    if not m:
        return None
    base, frac, zone = m.groups()
    frac = (frac or "0")[:6].ljust(6, "0")
    zone = "+00:00" if zone == "Z" else zone
    try:
        return datetime.fromisoformat(f"{base}.{frac}{zone}")
    except ValueError:
        return None


def how_long(a):
    start = parse_time(a.get("startsAt", ""))
    end = parse_time(a.get("endsAt", ""))
    if start is None or end is None or end < start:
        return ""
    secs = round((end - start).total_seconds())
    days, rest = divmod(secs, 86400)
    hours, rest = divmod(rest, 3600)
    mins, secs = divmod(rest, 60)
    parts = [f"{n} {u}" for n, u in ((days, "d"), (hours, "h"), (mins, "min")) if n]
    return " ".join(parts) if parts else f"{secs} s"


def messages(payload, host="nuc"):
    """One (icon, title, body, ping) per alert, in order."""
    out = []
    for a in payload.get("alerts", []):
        ann = a.get("annotations") or {}
        name = (a.get("labels") or {}).get("alertname", "alert")
        summary = ann.get("summary") or name
        body = ann.get("description", "")
        if a.get("status") == "resolved":
            lasted = how_long(a)
            if lasted:
                body = f"{body}\nLasted {lasted}." if body else f"Lasted {lasted}."
            out.append((RESOLVED, f"{host}: resolved: {summary}", body, False))
        else:
            out.append((FIRING, f"{host}: {summary}", body, True))
    return out


def handle(payload, sender, webhook_file, role_file, host):
    """Post every alert; True only if all posts succeeded."""
    ok = True
    alerts = payload.get("alerts", [])
    for a, (icon, title, body, ping) in zip(alerts, messages(payload, host)):
        name = (a.get("labels") or {}).get("alertname", "alert")
        try:
            r = subprocess.run(
                [sender, webhook_file, role_file if ping else "-", icon, title],
                input=body.encode(),
                timeout=SEND_TIMEOUT,
                check=False,
            )
            if r.returncode != 0:
                print(f"post of {name} failed: exit status {r.returncode}", file=sys.stderr, flush=True)
                ok = False
        except (OSError, subprocess.SubprocessError) as e:
            print(f"post of {name} failed: {type(e).__name__}", file=sys.stderr, flush=True)
            ok = False
    return ok


def status_for(payload, *args):
    return 200 if handle(payload, *args) else 500


def serve(sender, webhook_file, role_file, host, port):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                n = int(self.headers.get("Content-Length", ""))
                payload = json.loads(self.rfile.read(n))
                if not isinstance(payload, dict):
                    raise ValueError("not an object")
            except (ValueError, TypeError):
                self.send_response(400)
                self.end_headers()
                return
            self.send_response(status_for(payload, sender, webhook_file, role_file, host))
            self.end_headers()

        def log_message(self, fmt, *args):
            # The default logs every request line; the journal needs only
            # failures, which handle() reports.
            pass

    # One thread per request: a request held up by a slow post must not queue
    # the next behind it.
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit("usage: alert-relay.py SENDER WEBHOOK_FILE ROLE_FILE HOST PORT")
    serve(*sys.argv[1:5], int(sys.argv[5]))
