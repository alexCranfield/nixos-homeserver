#!/usr/bin/env python3
"""Weekly flake.lock update, ticket 2.2 (#17). See docs/runbooks/updates.md.

Two subcommands, one per job of .github/workflows/update-flake-lock.yml:

  update  Runs with a read-only token. Moves nixpkgs to the head of its
          channel and, when asked, every other direct input to the newest
          commit pushed to its branch at least COOLDOWN days ago. Writes the
          new lock and a report (package changes and the CVE (Common
          Vulnerabilities and Exposures) difference) to --out.
  check   Runs in the job that holds the write token, which runs no
          third-party code. Refuses a new lock that differs from the old one
          in anything but each node's rev, narHash and lastModified, or whose
          new commits are not descendants of the old ones on the branch the
          input follows. Then writes the pull request body from the two locks.

Standard library only, so the write-token job needs nothing but the runner's
own Python. Run with `python3 -I`.
"""

import argparse
import datetime
import http.client
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

NIXPKGS = "nixpkgs"
TOPLEVEL = ".#nixosConfigurations.nuc.config.system.build.toplevel"
# GitHub refuses a pull request body over 65,536 characters.
REPORT_LIMIT = 50_000
# diff-closures colours its sizes even when piped.
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# The only locked fields an update may change, and their formats.
MOVABLE = {
    "rev": re.compile(r"[0-9a-f]{40}"),
    "narHash": re.compile(r"sha256-[A-Za-z0-9+/]{43}="),
}

# Read once and removed from the environment, so programs this script starts
# do not inherit it. (Nix may hold a token of its own: install-nix-action can
# configure one.)
TOKEN = os.environ.pop("GITHUB_TOKEN", None)
# Network failures of a GitHub API call.
NET_ERRORS = (OSError, http.client.HTTPException, KeyError, ValueError)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(*cmd, check=True):
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, check=check, text=True, stdout=subprocess.PIPE)


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def utc(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.UTC)


def direct_inputs(lock):
    """Direct inputs, name -> node. A `follows` entry (a list) is skipped."""
    nodes = lock["nodes"]
    return {
        name: nodes[ref]
        for name, ref in nodes["root"]["inputs"].items()
        if isinstance(ref, str)
    }


def github(path):
    req = urllib.request.Request(f"https://api.github.com{path}")
    req.add_header("Accept", "application/vnd.github+json")
    if TOKEN:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def branch_of(original):
    owner, repo = original["owner"], original["repo"]
    return original.get("ref") or github(f"/repos/{owner}/{repo}")["default_branch"]


def on_branch(owner, repo, branch, old, new):
    """Why `new` is not a descendant of `old` still on `branch`, or None."""
    if github(f"/repos/{owner}/{repo}/compare/{old}...{new}")["status"] != "ahead":
        return f"{new[:10]} does not descend from {old[:10]}"
    status = github(f"/repos/{owner}/{repo}/compare/{new}...{branch}")["status"]
    if status not in ("ahead", "identical"):
        return f"{new[:10]} is not on {branch}"
    return None


def cooled_head(owner, repo, branch, cooldown):
    """The branch head as pushed at least `cooldown` ago, by GitHub's clock.

    Uses the repository's activity log, which records when each push reached
    GitHub. Commit dates are set by whoever made the commit and can be
    backdated, so they would not hold back a hijacked maintainer.
    Returns (sha, pushed at, force pushes in the log), sha None if no push in
    the last 100 is old enough.
    """
    pushes = github(f"/repos/{owner}/{repo}/activity"
                    f"?ref=refs/heads/{branch}&per_page=100")
    cutoff = datetime.datetime.now(datetime.UTC) - cooldown
    forced = [p["timestamp"][:10] for p in pushes
              if p["activity_type"] == "force_push"]
    for p in pushes:  # newest first
        at = datetime.datetime.fromisoformat(p["timestamp"])
        if at <= cutoff and p["activity_type"] != "branch_deletion":
            return p["after"], at, forced
    return None, None, forced


def cooled_commit(original, locked, cooldown):
    """(sha, pushed at, notes) for one input; sha None to leave it as is."""
    owner, repo = original["owner"], original["repo"]
    branch = branch_of(original)
    sha, at, forced = cooled_head(owner, repo, branch, cooldown)
    notes = [f"force pushes recorded on {', '.join(forced)}"] if forced else []
    if sha is None:
        return None, None, notes + ["no push old enough in the activity log"]
    if sha == locked["rev"]:
        return None, at, notes
    status = github(f"/repos/{owner}/{repo}/compare/{locked['rev']}...{sha}")["status"]
    if status == "behind":
        return None, at, notes + ["the locked commit is newer than the cooled head"]
    why = on_branch(owner, repo, branch, locked["rev"], sha)
    if why:
        return None, at, notes + [why]
    return sha, at, notes


def build_toplevel():
    out = run("nix", "build", "--no-link", "--print-out-paths", TOPLEVEL)
    return out.stdout.strip()


def vulnix(path, cache):
    """CVE ids per package in the runtime closure of `path`, None on failure."""
    # Exit 2 means vulnerabilities were found, the normal case, but vulnix
    # also exits 2 on an internal error; only a JSON list counts as a result.
    res = run(
        "nix", "run", "--inputs-from", ".", "nixpkgs#vulnix", "--",
        "--json", "--closure", "--cache-dir", cache, path,
        check=False,
    )
    if res.returncode not in (0, 2):
        return None
    try:
        data = json.loads(res.stdout)
    except ValueError:
        return None
    if not isinstance(data, list) or (res.returncode == 2 and not data):
        return None
    return {f"{p['pname']}-{p['version']}": set(p.get("affected_by", []))
            for p in data}


def cve_diff(old, new):
    """Lines for CVE ids that the update fixes and that it introduces."""
    if old is None or new is None:
        return ["vulnix failed; see the workflow log. No CVE comparison."]
    old_ids = set().union(*old.values()) if old else set()
    new_ids = set().union(*new.values()) if new else set()
    fixed, added = sorted(old_ids - new_ids), sorted(new_ids - old_ids)
    lines = [
        f"{len(old_ids)} CVE ids before, {len(new_ids)} after: "
        f"{len(fixed)} no longer reported, {len(added)} newly reported.",
        "",
    ]
    for title, ids, pkgs in (("Newly reported", added, new),
                              ("No longer reported", fixed, old)):
        if not ids:
            continue
        lines += [f"**{title}:**", ""]
        for pkg in sorted(pkgs):
            hit = sorted(pkgs[pkg] & set(ids))
            if hit:
                lines.append(f"- `{pkg}`: {', '.join(hit)}")
        lines.append("")
    return lines


def closure_report(old_top, new_top):
    diff = run("nix", "store", "diff-closures", old_top, new_top)
    lines = ANSI.sub("", diff.stdout).strip().splitlines()
    # Version changes in full; the whole list, mostly size changes and
    # packages renamed with a dependency (perl5.42.0-* to perl5.42.3-*, say),
    # folded away.
    versions = [ln for ln in lines if "→" in ln and "∅" not in ln]
    short = ["", "### Package changes on the nuc", "",
             f"From `nix store diff-closures`: {len(versions)} version "
             "changes:", "", "```", "\n".join(versions) or "(none)", "```", ""]
    full = ["<details>",
            f"<summary>Every change ({len(lines)} lines)</summary>", "",
            "```", "\n".join(lines) or "(none)", "```", "", "</details>", ""]
    return short, full


def cmd_update(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    old_lock = load("flake.lock")
    report = []

    old_top = build_toplevel() if args.report else None

    run("nix", "flake", "update", NIXPKGS)

    if args.others:
        cooldown = datetime.timedelta(days=args.cooldown_days)
        report += [f"Other inputs: the branch head as pushed at least "
                   f"{args.cooldown_days} days ago.", ""]
        for name, node in sorted(direct_inputs(old_lock).items()):
            if name == NIXPKGS:
                continue
            original, locked = node["original"], node["locked"]
            if original.get("type") != "github":
                report.append(f"- `{name}`: not a GitHub input, left as is.")
                continue
            try:
                sha, at, notes = cooled_commit(original, locked, cooldown)
            except NET_ERRORS as e:
                report.append(f"- `{name}`: lookup failed ({e!r}), left as is.")
                continue
            extra = f" ({'; '.join(notes)})" if notes else ""
            if sha is None:
                report.append(f"- `{name}`: unchanged{extra}.")
                continue
            report.append(f"- `{name}`: `{sha[:10]}`, pushed {at:%Y-%m-%d}"
                          f"{extra}.")
            run("nix", "flake", "lock", "--override-input", name,
                f"github:{original['owner']}/{original['repo']}/{sha}")
    else:
        report.append("Other inputs: not updated this week (monthly).")

    new_lock = load("flake.lock")
    changed = new_lock != old_lock
    if changed:
        shutil.copyfile("flake.lock", out / "flake.lock")

    full = []
    if changed and args.report:
        new_top = build_toplevel()
        short, full = closure_report(old_top, new_top)
        cache = str(out.parent / "vulnix-cache")
        report += short + [
            "### CVEs in the nuc's runtime closure", "",
            "From vulnix. It matches package names against the NVD (National "
            "Vulnerability Database) and does not know which fixes nixpkgs "
            "has patched in, so treat it as a pointer, not a verdict.", ""]
        report += cve_diff(vulnix(old_top, cache), vulnix(new_top, cache))

    text = "\n".join(report + full) + "\n"
    if len(text) > REPORT_LIMIT:
        # Drop the long list rather than cut a code block or <details> open.
        text = "\n".join(report + ["(Every change: see the workflow log.)"]) + "\n"
    (out / "report.md").write_text(text[:REPORT_LIMIT])
    (out / "changed").write_text("true\n" if changed else "false\n")
    log(f"changed: {changed}")


def lock_problems(old, new):
    """Every difference between the locks beyond what an update may change."""
    problems = []
    old_nodes, new_nodes = old.get("nodes", {}), new.get("nodes", {})
    if {k: v for k, v in old.items() if k != "nodes"} != \
            {k: v for k, v in new.items() if k != "nodes"}:
        problems.append("top-level fields changed")
    if set(old_nodes) != set(new_nodes):
        problems.append(f"nodes changed: added {sorted(set(new_nodes) - set(old_nodes))}, "
                        f"removed {sorted(set(old_nodes) - set(new_nodes))}")
    for name in sorted(set(old_nodes) & set(new_nodes)):
        o, n = old_nodes[name], new_nodes[name]
        if set(o) != set(n):
            problems.append(f"{name}: fields changed")
        for key in set(o) | set(n):
            if key != "locked" and o.get(key) != n.get(key):
                problems.append(f"{name}: {key} changed")
        if "locked" not in o:
            continue
        ol, nl = o["locked"], n.get("locked", {})
        if set(ol) != set(nl):
            problems.append(f"{name}: locked fields changed")
        for key in set(ol) | set(nl):
            if key in MOVABLE:
                if not isinstance(nl.get(key), str) or not MOVABLE[key].fullmatch(nl[key]):
                    problems.append(f"{name}: locked {key} malformed")
            elif key == "lastModified":
                if type(nl.get(key)) is not int:
                    problems.append(f"{name}: lastModified malformed")
            elif ol.get(key) != nl.get(key):
                problems.append(f"{name}: locked {key} changed")
        if ol.get("rev") == nl.get("rev"):
            if ol != nl:
                problems.append(f"{name}: hash or date changed without a new rev")
        elif ol.get("type") != "github":
            problems.append(f"{name}: moved, but is not a GitHub input")
    return problems


def cmd_check(args):
    old, new = load(args.old), load(args.new)
    problems = lock_problems(old, new)
    moved = []
    if not problems:
        for name in sorted(old["nodes"]):
            ol, nl = old["nodes"][name].get("locked"), new["nodes"][name].get("locked")
            if ol and ol.get("rev") != nl.get("rev"):
                moved.append((name, ol, nl))
        cooldown = datetime.timedelta(days=args.cooldown_days)
        for name, ol, nl in moved:
            original = old["nodes"][name]["original"]
            try:
                branch = branch_of(original)
                why = on_branch(ol["owner"], ol["repo"], branch, ol["rev"], nl["rev"])
                if not why and name != NIXPKGS:
                    # The update job runs code from the new nixpkgs, so it is
                    # not trusted to have applied the cooldown: check it here.
                    head, _, _ = cooled_head(ol["owner"], ol["repo"], branch, cooldown)
                    status = head and github(
                        f"/repos/{ol['owner']}/{ol['repo']}/compare/{nl['rev']}...{head}"
                    )["status"]
                    if status not in ("ahead", "identical"):
                        why = (f"{nl['rev'][:10]} was not on {branch} "
                               f"{args.cooldown_days} days ago")
            except NET_ERRORS as e:
                why = f"could not check ({e!r})"
            if why:
                problems.append(f"{name}: {why}")
    if problems:
        sys.exit("refusing the new lock:\n  " + "\n  ".join(problems))

    now = datetime.datetime.now(datetime.UTC)
    direct = set(direct_inputs(new))
    rows = ["| Input | From | To | Commit date | Changes |",
            "|---|---|---|---|---|"]
    for name, ol, nl in moved:
        label = f"`{name}`" if name in direct else f"`{name}` (input of an input)"
        compare = (f"https://github.com/{nl['owner']}/{nl['repo']}/compare/"
                   f"{ol['rev']}...{nl['rev']}")
        day = utc(nl["lastModified"])
        rows.append(f"| {label} | `{ol['rev'][:10]}` | `{nl['rev'][:10]}` | "
                    f"{day:%Y-%m-%d} ({(now - day).days} days) | "
                    f"[diff]({compare}) |")

    report = pathlib.Path(args.report).read_text()[:REPORT_LIMIT]
    body = [
        "Automated weekly `flake.lock` update (ticket 2.2, #17; "
        "docs/runbooks/updates.md).",
        "",
        "**To run CI (continuous integration): close this pull request and "
        "reopen it.** GitHub does not start workflows for pull requests "
        "opened by a workflow.",
        "",
        "Review the source diff of every input other than nixpkgs: each runs "
        "as root on the nuc once merged, and comin deploys it within a "
        "minute. Commit dates are the committer's own; the cooldown goes by "
        "push time instead.",
        "",
        "### Inputs",
        "",
        "Checked by the job that opens this pull request: every change below "
        "is a commit that descends from the old one on the input's branch "
        f"and, except for nixpkgs, was there {args.cooldown_days} days ago.",
        "",
        *rows,
        "",
        "## From the update job",
        "",
        "Not checked: the job that wrote this also ran the new inputs' code.",
        "",
        report,
        "",
        "🤖 Opened by `.github/workflows/update-flake-lock.yml`",
    ]
    pathlib.Path(args.body).write_text("\n".join(body) + "\n")


def cmd_carry(args):
    """Exit 0 if the open pull request's lock moved an input other than
    nixpkgs, so this week's run must update them too or drop the change."""
    main_in, pr_in = direct_inputs(load(args.main)), direct_inputs(load(args.pr))
    for name in main_in:
        if name != NIXPKGS and name in pr_in and \
                main_in[name]["locked"].get("rev") != pr_in[name]["locked"].get("rev"):
            sys.exit(0)
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("update")
    u.add_argument("--out", required=True)
    u.add_argument("--others", action="store_true",
                   help="also update inputs other than nixpkgs")
    u.add_argument("--cooldown-days", type=int, default=7)
    u.add_argument("--no-report", dest="report", action="store_false",
                   help="skip the builds, the closure diff and vulnix")
    c = sub.add_parser("check")
    c.add_argument("--old", required=True)
    c.add_argument("--new", required=True)
    c.add_argument("--report", required=True)
    c.add_argument("--body", required=True)
    c.add_argument("--cooldown-days", type=int, default=7)
    k = sub.add_parser("carry")
    k.add_argument("--main", required=True)
    k.add_argument("--pr", required=True)
    args = p.parse_args()
    {"update": cmd_update, "check": cmd_check, "carry": cmd_carry}[args.cmd](args)


if __name__ == "__main__":
    main()
