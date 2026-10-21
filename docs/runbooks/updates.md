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
  sops-nix, comin, disko and home-manager each move to what their branch held
  at least seven days ago. The age comes from GitHub's activity log, which
  records when each push arrived, not from commit dates, which the committer
  sets and an attacker can backdate. Their code runs as root on the nuc, and
  they are small projects where a hijacked maintainer account is the likeliest
  attack. The delay is a bet that such a release is noticed and reverted
  within a week; it is not a guarantee, so read the diffs anyway.
- **Monthly updates are not dropped.** If last week's pull request, still
  open, moved those inputs, this week's run moves them again rather than
  replacing the pull request with a nixpkgs-only one.
- **Nothing to do, nothing opened.** A week with no change opens no pull
  request.

The workflow keeps one pull request, from the branch `update/flake-lock`, and
replaces its commit and description at each run while it is open. It
force-pushes that branch, so a commit added to it by hand is lost at the next
run.

## Reviewing one

1. **Close the pull request and reopen it.** GitHub does not start workflows,
   CI (continuous integration) included, for a pull request a workflow opened,
   and `main` cannot merge without a green `check`. Reopening counts as Alex's
   action, so CI runs. A machine account (#61) would make this unnecessary.
2. **Read the inputs table.** Every input that moved, with a link to its source
   diff, written by the job that checked them. The commit date beside each comes
   from the lock and is the committer's own, unchecked. For anything but
   nixpkgs, read the diff: it is short, and it becomes root on the nuc. A row
   marked "input of an input" moved because an input's own lock did. Everything
   under "From the update job" was written by the job that ran the new code, and
   is unchecked.
3. **Read the package changes** (`nix store diff-closures` between the running
   system and the new one). A kernel series change (7.2 to 7.3, say) needs a
   reboot to take effect, which is #18's.
4. **Read the CVE (Common Vulnerabilities and Exposures) change.** vulnix lists
   the CVE ids reported against the nuc's runtime closure before and after.
   It matches package names against the NVD (National Vulnerability Database)
   and does not know which fixes nixpkgs has patched in, so most entries are
   false positives; what matters is what the update adds. It informs; it does
   not block. Its first step downloads the NVD data, which timed out on
   GitHub's runner on 2026-10-21, so it is tried three times; if all fail, the
   pull request says so and shows no comparison.
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
  input, with the commit picked from the activity log and confirmed to descend
  from the locked one on the input's branch. It builds the old and the new
  system to compare them and runs vulnix, then hands the lock and a report to
  the next job as an artifact.
- **`pr`, write token, from `main` only.** Runs only GitHub's checkout and
  artifact actions, git, `gh` and `scripts/flake_update.py check` on the
  runner's own Python. `check` refuses a lock that differs from `main`'s in
  anything but each node's `rev`, `narHash` and `lastModified`: no new,
  removed or renamed node, no changed wiring between inputs, no other host,
  owner or repository. Commit ids and hashes must be well formed, and every
  moved commit must descend from the old one and still be on the branch the
  input follows, which rules out a commit that exists only in a fork. It then
  writes the description from the two locks itself. For inputs other than
  nixpkgs it also applies the cooldown again: the update job runs code from the
  new nixpkgs, so it is not trusted to have done so.

If an input's own lock gains or loses an input, `check` refuses that week's
update; update it by hand in a reviewed pull request. It can also refuse one
because an input of an input (flake-compat, say) fails the cooldown, which the
first job does not apply to those, or because a repository's activity log has
no push old enough. Either way the whole week's update is refused, nixpkgs
included; the next run, or a hand update, follows.

`main`'s ruleset needs a green check but no approval, so anything holding a
write token could merge a green pull request, and comin would deploy it. That
is why the write token stays away from third-party code, and why nothing merges
by itself (ADR 0003 records the decision on auto-merge).

Determinate Systems' `update-flake-lock` action was not used: it runs a compiled
bundle and five more third-party actions in the job with the write token, and
cannot apply the cooldown. See `docs/q-and-a/security.md`.

## Running it by hand

From the Actions tab, "Update flake.lock", "Run workflow"; tick the box to
update the other inputs too, outside the monthly run. Only a run from `main`
opens or updates the pull request; from another branch, the first job runs and
the second is skipped.

To reject an update, close its pull request. A closed one is not carried into
the next week's run, but the next monthly run proposes the same inputs again if
they are still the cooled heads.

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
