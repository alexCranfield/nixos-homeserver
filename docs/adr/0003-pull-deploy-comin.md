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
  pushing to `main`, which the ruleset forbids. The risk accepted is that
  whoever controls the GitHub account, or GitHub itself, can deploy to the nuc
  as root; a check against Alex's key is what would have prevented that.
  Revisit if direct pushes to `main` stop being rare: they have happened, with
  the ruleset switched off for history rewrites, which comin refuses anyway as
  not fast-forward, but an ordinary direct push would deploy unsigned.
- Also as built: comin does not run `nixos-rebuild switch`. It runs
  `switch-to-configuration` under its own profile,
  `/nix/var/nix/profiles/system-profiles/comin`, so the `system` profile moves
  only on a manual deploy, and `nixos-rebuild --rollback` does not undo a comin
  deploy. Rollback is ticket 2.4 (#19). See `docs/runbooks/deploy.md`.
- As built (ticket 2.2, #17, 2026-10-20):
  `.github/workflows/update-flake-lock.yml` opens the weekly pull request, written in this repo rather than taken from
  Determinate Systems' `update-flake-lock` action. That action runs a compiled
  bundle and five more third-party actions in the job holding the token that
  opens pull requests, and since the ruleset needs no approval, that token can
  also merge a green one, which comin then deploys as root. Here the job that
  runs Nix and fetches the new inputs has a read-only token, and the job with
  the write token runs no third-party code and refuses a lock that adds an
  input or moves one to another repository. nixpkgs moves weekly; the other
  inputs monthly, and only to commits at least seven days old. Nothing merges
  by itself: auto-merge stays off until a month of these pull requests has
  been seen, and is not planned for inputs other than nixpkgs. Pull requests
  opened by the workflow do not start CI until someone closes and reopens
  them; a machine account (#61) would change that. See
  `docs/runbooks/updates.md`.
