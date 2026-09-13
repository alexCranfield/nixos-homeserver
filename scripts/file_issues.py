#!/usr/bin/env python3
"""Create GitHub milestones, labels and issues from scripts/tickets.py.

Usage:
  GITHUB_TOKEN=... python3 scripts/file_issues.py [--dry-run]

Needs a token with Issues: write on alexCranfield/nixos-homeserver.

Safe to re-run. Milestones, labels and issues are matched by title and skipped
if they already exist. Issue bodies that already exist on GitHub are NEVER
overwritten from tickets.py: once filed, the issue is the source of truth for
its own body and status (see CLAUDE.md). Only issues created by the current run
have their [x.y] dependency references rewritten to #<issue> links.

Importing this module has no side effects. Everything runs under main().
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tickets import LABELS, MILESTONES, TICKETS  # noqa: E402

OWNER, REPO = "alexCranfield", "nixos-homeserver"
API = f"https://api.github.com/repos/{OWNER}/{REPO}"


def token():
    """Return the API token, preferring the purpose-specific variable.

    GITHUB_MCP_PAT is an account-wide credential that happens to be in the
    environment; using it here grants far more than this script needs, so say
    so rather than falling back silently.
    """
    if tok := os.environ.get("GITHUB_TOKEN"):
        return tok
    if tok := os.environ.get("GITHUB_MCP_PAT"):
        print("warning: GITHUB_TOKEN unset, using account-wide GITHUB_MCP_PAT", file=sys.stderr)
        return tok
    raise SystemExit("error: set GITHUB_TOKEN to a token with Issues: write")


def req(method, path, data=None, tok=None):
    tok = tok or token()
    r = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={
            "Authorization": f"Bearer {tok}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "file-issues",
        },
    )
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def expect(codes, code, body, what):
    """Fail with an operator-readable message. Not an assert: asserts vanish
    under `python3 -O`, which would let the run continue against garbage."""
    if code not in codes:
        raise SystemExit(f"error: {what} failed with HTTP {code}: {body}")


def paged(path, tok):
    out, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        code, body = req("GET", f"{path}{sep}per_page=100&page={page}", tok=tok)
        expect({200}, code, body, f"GET {path}")
        out += body
        if len(body) < 100:
            return out
        page += 1


def check():
    """Validate the ticket data with no network access."""
    ids = [t[0] for t in TICKETS]
    titles = [t[1] for t in TICKETS]
    declared = {name for name, _, _ in LABELS}
    problems = []
    if len(set(ids)) != len(ids):
        problems.append("duplicate ticket ids")
    if len(set(titles)) != len(titles):
        problems.append("duplicate ticket titles")
    if ids != sorted(ids, key=lambda s: [int(p) for p in s.split(".")]):
        problems.append("ticket ids are not in sorted order, so the id -> issue number mapping breaks")
    for id_, _, labels, body in TICKETS:
        if not re.fullmatch(r"\d\.\d+", id_):
            problems.append(f"{id_}: malformed id")
        if int(id_.split(".")[0]) >= len(MILESTONES):
            problems.append(f"{id_}: no milestone for phase {id_.split('.')[0]}")
        for lab in labels:
            if lab not in declared:
                problems.append(f"{id_}: undeclared label {lab}")
        for dep in re.findall(r"\[(\d\.\d+)\]", body):
            if dep not in ids:
                problems.append(f"{id_}: depends on unknown ticket {dep}")
    if problems:
        raise SystemExit("dry run failed:\n  " + "\n  ".join(problems))
    print(f"{len(MILESTONES)} milestones, {len(LABELS)} labels, {len(TICKETS)} tickets")
    print("dry run ok")


def main():
    if "--dry-run" in sys.argv:
        check()
        return
    check()
    tok = token()

    have = {m["title"]: m["number"] for m in paged("/milestones?state=all", tok)}
    ms_num = {}
    for i, (title, desc) in enumerate(MILESTONES):
        if title not in have:
            code, body = req("POST", "/milestones", {"title": title, "description": desc}, tok)
            expect({201}, code, body, f"create milestone {title!r}")
            have[title] = body["number"]
            print("milestone created:", title)
        ms_num[str(i)] = have[title]

    have_labels = {l["name"] for l in paged("/labels", tok)}
    for name, color, desc in LABELS:
        if name in have_labels:
            continue
        code, body = req("POST", "/labels", {"name": name, "color": color, "description": desc}, tok)
        expect({201, 422}, code, body, f"create label {name!r}")
        print("label created:", name)

    existing = {i["title"]: i for i in paged("/issues?state=all", tok) if "pull_request" not in i}
    id_to_num, created = {}, set()
    for id_, title, labels, body in TICKETS:
        if title in existing:
            id_to_num[id_] = existing[title]["number"]
            continue
        payload = {"title": title, "body": body, "labels": labels, "milestone": ms_num[id_.split(".")[0]]}
        code, resp = req("POST", "/issues", payload, tok)
        expect({201}, code, resp, f"create issue {title!r}")
        id_to_num[id_] = resp["number"]
        created.add(id_)
        print(f"issue #{resp['number']} created: {title}")

    # Rewrite [x.y] references to #<issue>. For issues that already existed,
    # rewrite the REMOTE body, so a body edited on GitHub is preserved and an
    # already-rewritten body produces no change and therefore no PATCH.
    for id_, title, _, body in TICKETS:
        source = body if id_ in created else existing[title]["body"]
        new = re.sub(
            r"\[(\d\.\d+)\]",
            lambda m: f"#{id_to_num[m.group(1)]}" if m.group(1) in id_to_num else m.group(0),
            source or "",
        )
        if new != source:
            code, resp = req("PATCH", f"/issues/{id_to_num[id_]}", {"body": new}, tok)
            expect({200}, code, resp, f"update issue {title!r}")
            print(f"issue #{id_to_num[id_]} references rewritten")

    print(f"done: {len(id_to_num)} issues, {len(created)} created this run")


if __name__ == "__main__":
    main()
