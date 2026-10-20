# Updates: the weekly `flake.lock` pull request

Ticket 2.2 (#17), ADR (Architecture Decision Record) 0003. Ticket 2.3 (#18)
adds kernel reboots and the maintenance window here later.

Everything the nuc runs is pinned in `flake.lock`: each input to a commit and a
content hash. Nothing changes until the lock does, and the lock changes only
through a reviewed pull request. Once one merges, comin deploys it within about
a minute ([deploy.md](deploy.md)).

## What runs, and when

`.github/workflows/update-flake-lock.yml`, every Monday at 06:00 UTC
(Coordinated Universal Time); GitHub may start it late.

- **nixpkgs, weekly.** It moves to the head of the `nixos-26.05` channel,
  which only advances once Hydra, NixOS's build farm, has built and tested it.
- **The other inputs, monthly.** On the first Monday of the month (day 1 to 7)
  sops-nix, comin, disko and home-manager each move to the newest commit on
  their branch that is at least seven days old, never to a fresh one. Their
  code runs as root on the nuc, and they are small projects where a hijacked
  maintainer account is the likeliest attack; a compromised release has
  usually been caught within days.
- **Nothing to do, nothing opened.** A week with no change opens no pull
  request.

The workflow keeps one pull request, from the branch `update/flake-lock`, and
replaces its commit and description at each run while it is open.

## Reviewing one

1. **Close the pull request and reopen it.** GitHub does not start workflows,
   CI (continuous integration) included, for a pull request a workflow opened,
   and `main` cannot merge without a green `check`. Reopening counts as Alex's
   action, so CI runs. A machine account (#61) would make this unnecessary.
2. **Read the inputs table.** Every input that moved, with the date and age of
   its new commit and a link to its source diff. For anything but nixpkgs, read
   the diff: it is short, and it becomes root on the nuc. A new "input of
   inputs" line means an input's own lock gained one; check where it comes
   from.
3. **Read the package changes** (`nix store diff-closures` between the running
   system and the new one). A kernel series change (7.2 to 7.3, say) needs a
   reboot to take effect, which is #18's.
4. **Read the CVE (Common Vulnerabilities and Exposures) change.** vulnix lists
   the CVE ids reported against the nuc's runtime closure before and after.
   It matches package names against the NVD (National Vulnerability Database)
   and does not know which fixes nixpkgs has patched in, so most entries are
   false positives; what matters is what the update adds. It informs; it does
   not block.
5. **Merge once `check` is green.** Then confirm the deploy as in
   [deploy.md](deploy.md), "Is it working?".

GitHub emails a notification when the pull request opens, with the description
in it. Phone alerts for failed deploys are ticket 2.5 (#20).

## How it is built, and why

Two jobs, so the token that can open pull requests never runs anyone else's
code (ADR 0003):

- **`update`, read-only token.** Installs Nix and runs
  `scripts/flake_update.py update`: `nix flake update nixpkgs`, then, monthly,
  `nix flake lock --override-input <name> github:<owner>/<repo>/<commit>` per
  input, with the commit picked from the GitHub API. It builds the old and the
  new system to compare them and runs vulnix, then hands the lock and a report
  to the next job as an artifact.
- **`pr`, write token.** Runs only GitHub's checkout and artifact actions, git,
  `gh` and `scripts/flake_update.py check` on the runner's own Python. `check`
  refuses a lock that adds or removes inputs or moves any input, or input of
  an input, to a different repository, and writes the description from the
  old and new locks itself.

`main`'s ruleset needs a green check but no approval, so anything holding a
write token could merge a green pull request, and comin would deploy it. That
is why the write token stays away from third-party code, and why nothing merges
by itself (ADR 0003 records the decision on auto-merge).

Determinate Systems' `update-flake-lock` action was not used: it runs a compiled
bundle and five more third-party actions in the job with the write token, and
cannot apply the cooldown. See `docs/q-and-a/security.md`.

## Running it by hand

From the Actions tab, "Update flake.lock", "Run workflow"; tick the box to
update the other inputs too, outside the monthly run. It runs the workflow from
the branch chosen there.

To see what an update would do without opening anything, run the first job's
script on a scratch copy of the repo (it rewrites `flake.lock` in place):

```bash
nix develop -c python3 -I scripts/flake_update.py update --out /tmp/lock-out --others
```

`/tmp/lock-out` then holds the new `flake.lock`, `report.md` and `changed`.
`--no-report` skips the two system builds and vulnix.

## Settings it depends on

- **"Allow GitHub Actions to create and approve pull requests"** (Settings,
  Actions, General) must be on, or `gh pr create` is refused. It also lets
  workflows approve pull requests, which matters only if `main` ever requires
  an approval.
- **The `dependencies` label** must exist; the workflow applies it.
- GitHub turns scheduled workflows off in a public repository after 60 days
  without activity. The Actions tab shows it; re-enable it there.

## Record

| | |
|---|---|
| First automated pull request | to be filled in |
| First deploy of one by comin | to be filled in |
