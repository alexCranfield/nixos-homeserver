#!/usr/bin/env python3
"""Weekly flake.lock update, ticket 2.2 (#17). See docs/runbooks/updates.md.

Two subcommands, one per job of .github/workflows/update-flake-lock.yml:

  update  Runs with a read-only token. Moves nixpkgs to the head of its
          channel and, when asked, every other direct input to its newest
          commit at least COOLDOWN days old. Writes the new lock and a report
          (package changes and the CVE (Common Vulnerabilities and Exposures)
          difference) to --out.
  check   Runs in the job that holds the write token, which runs no
          third-party code. Refuses a lock from `update` that adds or removes
          inputs or points one at a different repository, then writes the pull
          request body from the old and new locks.

Standard library only, so the write-token job needs nothing but the runner's
own Python. Run with `python3 -I`.
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

NIXPKGS = "nixpkgs"
TOPLEVEL = ".#nixosConfigurations.nuc.config.system.build.toplevel"
# GitHub refuses a pull request body over 65,536 characters.
REPORT_LIMIT = 50_000
# diff-closures colours its sizes even when piped.
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(*cmd, check=True):
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, check=check, text=True, stdout=subprocess.PIPE)


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def direct_inputs(lock):
    """Direct inputs of the flake, name -> node, as flake.lock records them."""
    nodes = lock["nodes"]
    return {name: nodes[ref] for name, ref in nodes["root"]["inputs"].items()}


def github(path):
    req = urllib.request.Request(f"https://api.github.com{path}")
    req.add_header("Accept", "application/vnd.github+json")
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def cooled_commit(original, cooldown):
    """Newest commit on the input's branch that is at least `cooldown` old."""
    owner, repo = original["owner"], original["repo"]
    branch = original.get("ref") or github(f"/repos/{owner}/{repo}")["default_branch"]
    until = datetime.datetime.now(datetime.UTC) - cooldown
    commits = github(
        f"/repos/{owner}/{repo}/commits?sha={branch}"
        f"&until={until.strftime('%Y-%m-%dT%H:%M:%SZ')}&per_page=1"
    )
    if not commits:
        return None, None
    c = commits[0]
    date = datetime.datetime.fromisoformat(c["commit"]["committer"]["date"])
    return c["sha"], date


def build_toplevel():
    out = run("nix", "build", "--no-link", "--print-out-paths", TOPLEVEL)
    return out.stdout.strip()


def vulnix(path, cache):
    """CVE ids per package name in the runtime closure of `path`."""
    # Exit 2 means vulnerabilities were found, which is the normal case.
    res = run(
        "nix", "run", "--inputs-from", ".", "nixpkgs#vulnix", "--",
        "--json", "--closure", "--cache-dir", cache, path,
        check=False,
    )
    if res.returncode not in (0, 2):
        return None
    found = {}
    for pkg in json.loads(res.stdout or "[]"):
        name = f"{pkg['pname']}-{pkg['version']}"
        found[name] = set(pkg.get("affected_by", []))
    return found


def cve_diff(old, new):
    """Lines for CVE ids that the update fixes and that it introduces."""
    if old is None or new is None:
        return ["vulnix failed; see the workflow log."]
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
        lines.append(f"**{title}:**")
        lines.append("")
        for pkg in sorted(pkgs):
            hit = sorted(pkgs[pkg] & set(ids))
            if hit:
                lines.append(f"- `{pkg}`: {', '.join(hit)}")
        lines.append("")
    return lines


def cmd_update(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    old_lock = load("flake.lock")
    report = []

    old_top = build_toplevel() if args.report else None

    run("nix", "flake", "update", NIXPKGS)

    if args.others:
        cooldown = datetime.timedelta(days=args.cooldown_days)
        report.append(f"Other inputs: newest commit at least "
                      f"{args.cooldown_days} days old.")
        for name, node in direct_inputs(old_lock).items():
            if name == NIXPKGS:
                continue
            original, locked = node["original"], node["locked"]
            if original.get("type") != "github":
                report.append(f"- `{name}`: not a GitHub input, left as is.")
                continue
            sha, date = cooled_commit(original, cooldown)
            current = datetime.datetime.fromtimestamp(
                locked["lastModified"], datetime.UTC)
            if sha is None or sha == locked["rev"] or date <= current:
                report.append(f"- `{name}`: no commit old enough and newer "
                              "than the locked one.")
                continue
            run("nix", "flake", "lock", "--override-input", name,
                f"github:{original['owner']}/{original['repo']}/{sha}")
    else:
        report.append("Other inputs: not updated this week (monthly).")

    new_lock = load("flake.lock")
    changed = new_lock != old_lock
    if changed:
        (out / "flake.lock").write_text(json.dumps(new_lock, indent=2) + "\n")

    if changed and args.report:
        new_top = build_toplevel()
        diff = run("nix", "store", "diff-closures", old_top, new_top)
        lines = ANSI.sub("", diff.stdout).strip().splitlines()
        cache = str(out.parent / "vulnix-cache")
        # Version changes in full; the whole list, mostly size changes and
        # packages renamed with a dependency (perl5.42.0-* to perl5.42.3-*,
        # say), folded away.
        versions = [ln for ln in lines if "→" in ln and "∅" not in ln]
        report += ["", "### Package changes on the nuc", "",
                   f"From `nix store diff-closures`: {len(versions)} version "
                   "changes:", "", "```", "\n".join(versions) or "(none)",
                   "```", "", "<details>",
                   f"<summary>Every change ({len(lines)} lines)</summary>", "",
                   "```", "\n".join(lines) or "(none)", "```", "",
                   "</details>", "",
                   "### CVEs in the nuc's runtime closure", "",
                   "From vulnix. It matches package names against the NVD "
                   "(National Vulnerability Database) and does not know "
                   "which fixes nixpkgs has patched in, so treat it as a "
                   "pointer, not a verdict.", ""]
        report += cve_diff(vulnix(old_top, cache), vulnix(new_top, cache))

    text = "\n".join(report) + "\n"
    if len(text) > REPORT_LIMIT:
        text = text[:REPORT_LIMIT] + "\n\n(truncated; see the workflow log)\n"
    (out / "report.md").write_text(text)
    (out / "changed").write_text("true\n" if changed else "false\n")
    log(f"changed: {changed}")


def short(node):
    lk = node["locked"]
    day = datetime.datetime.fromtimestamp(lk["lastModified"], datetime.UTC)
    return lk.get("rev", "")[:10], day


def cmd_check(args):
    old, new = load(args.old), load(args.new)
    old_in, new_in = direct_inputs(old), direct_inputs(new)
    problems = []
    if set(old_in) != set(new_in):
        problems.append(f"inputs changed: {sorted(old_in)} -> {sorted(new_in)}")
    for name in sorted(set(old_in) & set(new_in)):
        o, n = old_in[name], new_in[name]
        if o["original"] != n["original"]:
            problems.append(f"{name}: original changed")
        for key in ("type", "owner", "repo"):
            if o["locked"].get(key) != n["locked"].get(key):
                problems.append(f"{name}: locked {key} changed")
    # Inputs of inputs too: one that keeps its name but moves to another
    # repository is refused. A new one is allowed, since an input's own lock
    # can gain inputs, but listed in the body.
    old_nodes, new_nodes = old["nodes"], new["nodes"]
    for name in sorted(set(old_nodes) & set(new_nodes) - {"root"}):
        for key in ("type", "owner", "repo"):
            if (old_nodes[name].get("locked", {}).get(key)
                    != new_nodes[name].get("locked", {}).get(key)):
                problems.append(f"node {name}: locked {key} changed")
    if problems:
        sys.exit("refusing the new lock:\n  " + "\n  ".join(problems))
    added = sorted(set(new_nodes) - set(old_nodes))

    now = datetime.datetime.now(datetime.UTC)
    rows = ["| Input | From | To | Age of new commit | Changes |",
            "|---|---|---|---|---|"]
    for name in sorted(new_in):
        o, n = old_in[name], new_in[name]
        if o["locked"].get("rev") == n["locked"].get("rev"):
            continue
        (orev, oday), (nrev, nday) = short(o), short(n)
        lk = n["locked"]
        compare = (f"https://github.com/{lk['owner']}/{lk['repo']}/compare/"
                   f"{o['locked']['rev']}...{lk['rev']}")
        rows.append(f"| `{name}` | `{orev}` {oday:%Y-%m-%d} | `{nrev}` "
                    f"{nday:%Y-%m-%d} | {(now - nday).days} days | "
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
        "minute.",
        "",
        "### Inputs",
        "",
        *rows,
        "",
        *([f"**New inputs of inputs:** {', '.join(f'`{a}`' for a in added)}"
           " — check where each comes from.", ""] if added else []),
        report,
        "",
        "🤖 Opened by `.github/workflows/update-flake-lock.yml`",
    ]
    pathlib.Path(args.body).write_text("\n".join(body) + "\n")


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
    args = p.parse_args()
    {"update": cmd_update, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    main()
