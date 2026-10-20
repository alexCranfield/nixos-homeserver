# ADR 0003: Pull-based deployment with comin, validated by GitHub Actions

Date: 2026-09-07. Status: accepted.

## Context
Options were: push from the workstation (`nixos-rebuild --target-host`), a self-hosted GitHub Actions runner on the server, or the server pulling from the repo. The repo is public so it can serve as portfolio evidence, which makes a self-hosted runner risky: anyone's pull request could run code on the machine.

## Decision
GitHub-hosted Actions run `nix flake check`, build the system closure and check formatting on every pull request and push. The server runs comin, which polls `main` roughly every 60 seconds and runs `nixos-rebuild switch` on new commits. A manual push target remains for emergencies. A weekly Action opens a pull request bumping `flake.lock`.

## Consequences
- Nothing on the server accepts inbound connections for deployment.
- Deploy latency is about a minute after merge.
- CI (continuous integration) cannot test hardware-specific behaviour; the VM build catches most config errors.
- `main` is protected by a ruleset requiring a pull request, added 2026-09-13
  after a defect reached `main` unreviewed. The repository was also found to be
  private on that date, contrary to this record; it was made public, which is
  what makes rulesets and unmetered Actions minutes available and lets comin
  pull without credentials.
- Broken commits on `main` are caught by CI before merge; if one slips through, the previous generation still boots.
- As built (ticket 0.4, #4, 2026-09-29): the workflow runs `just check`, which
  covers the three checks above plus `.editorconfig` conformance, and `check`
  is a required status check on `main`, so a red pull request cannot merge.
  The weekly `flake.lock` pull request is ticket 2.2 and does not exist yet.
  See `docs/runbooks/ci.md`.
- As built (ticket 2.1, #16, 2026-10-20): `modules/base/comin.nix` polls
  `main` every 60 seconds over HTTPS. comin's testing branch is turned off,
  since a push to `testing-nuc` would deploy without a pull request; the flake
  check `comin` confirms it is ignored. Commit signatures are not checked.
  GitHub makes the squash merges and signs them with its own key, so trusting
  that key proves only that a commit came through GitHub, which the ruleset
  already ensures; requiring Alex's key would mean merging locally and
  pushing to `main`, which the ruleset forbids. Revisit if `main` ever accepts
  commits from anywhere but GitHub's merge button. See
  `docs/runbooks/deploy.md`.
