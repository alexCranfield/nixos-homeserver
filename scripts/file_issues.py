#!/usr/bin/env python3
"""Idempotently create milestones, labels and issues from scripts/tickets.py.

Usage:
  GITHUB_TOKEN=... python3 scripts/file_issues.py [--dry-run]

Needs a token with Issues: write on alexCranfield/nixos-homeserver.
Safe to re-run: existing milestones/labels/issues (matched by title) are skipped;
dependency references like [1.3] are rewritten to #<issue> links on every run.
"""
import json, os, re, sys, urllib.request, urllib.error

sys.path.insert(0, os.path.dirname(__file__))
from tickets import MILESTONES, LABELS, TICKETS

OWNER, REPO = "alexCranfield", "nixos-homeserver"
API = f"https://api.github.com/repos/{OWNER}/{REPO}"
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GITHUB_MCP_PAT")
DRY = "--dry-run" in sys.argv
if not TOKEN and not DRY:
    sys.exit("set GITHUB_TOKEN")


def req(method, path, data=None):
    r = urllib.request.Request(API + path, method=method, data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json", "User-Agent": "file-issues"})
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def paged(path):
    out, page = [], 1
    while True:
        code, body = req("GET", f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
        assert code == 200, (path, code, body)
        out += body
        if len(body) < 100:
            return out
        page += 1


if DRY:
    print(f"{len(MILESTONES)} milestones, {len(LABELS)} labels, {len(TICKETS)} tickets")
    for id_, title, labels, body in TICKETS:
        assert re.fullmatch(r"\d\.\d+", id_), id_
        for dep in re.findall(r"\[(\d\.\d+)\]", body):
            assert any(t[0] == dep for t in TICKETS), f"{id_} depends on unknown {dep}"
    print("dry run ok")
    sys.exit(0)

# milestones
have = {m["title"]: m["number"] for m in paged("/milestones?state=all")}
ms_num = {}
for i, (title, desc) in enumerate(MILESTONES):
    if title not in have:
        code, body = req("POST", "/milestones", {"title": title, "description": desc})
        assert code == 201, (title, code, body)
        have[title] = body["number"]
        print("milestone created:", title)
    ms_num[str(i)] = have[title]

# labels
have_labels = {l["name"] for l in paged("/labels")}
for name, color, desc in LABELS:
    if name not in have_labels:
        code, body = req("POST", "/labels", {"name": name, "color": color, "description": desc})
        assert code == 201, (name, code, body)
        print("label created:", name)

# issues
existing = {i["title"]: i["number"] for i in paged("/issues?state=all") if "pull_request" not in i}
id_to_num = {}
for id_, title, labels, body in TICKETS:
    if title in existing:
        id_to_num[id_] = existing[title]
        continue
    code, resp = req("POST", "/issues", {"title": title, "body": body, "labels": labels, "milestone": ms_num[id_.split(".")[0]]})
    assert code == 201, (title, code, resp)
    id_to_num[id_] = resp["number"]
    print(f"issue #{resp['number']} created: {title}")

# rewrite [x.y] references to #n
for id_, title, labels, body in TICKETS:
    new = re.sub(r"\[(\d\.\d+)\]", lambda m: f"#{id_to_num[m.group(1)]}" if m.group(1) in id_to_num else m.group(0), body)
    if new != body:
        code, resp = req("PATCH", f"/issues/{id_to_num[id_]}", {"body": new})
        assert code == 200, (title, code, resp)
print(f"done: {len(id_to_num)} issues")
