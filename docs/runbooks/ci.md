# CI (continuous integration)

What runs on GitHub when a pull request (PR) is opened or `main` changes, why it
is built the way it is, and what to do when it goes red. Ticket 0.4 (#4).

## What runs

`.github/workflows/ci.yml` has one job, `check`, on GitHub-hosted Ubuntu runners.
It triggers on every pull request, every push to `main`, and by hand from the
Actions tab (`workflow_dispatch`). It checks out the repo, installs Nix, and runs:

```sh
nix develop --command just check
```

`just check` is the same target you run locally: `nix flake check`, a build of
the nuc system closure, and `nix fmt -- --ci`. The workflow does not restate
those commands, so changing what "checked" means is a change to the `justfile`,
and the workstation and CI change together.

`check` is a required status check on `main` (ruleset `main`), so a PR cannot
merge while it is red or still running.

## Reproducing a failure locally

Run the same command from the repo root:

```sh
just check
```

If it passes locally but fails in CI, the difference is almost always one of:

- **An uncommitted change.** Locally, a flake sees every file git tracks,
  including edits not yet committed (Nix warns that the tree is dirty). CI sees
  only what was pushed. `git status` first.
- **Running outside the dev shell.** Without direnv, `just check` uses the
  workstation's Determinate Nix instead of the server's version. Use
  `nix develop -c just check` to match CI exactly.
- **Formatting.** `just fmt`, commit, push.

## Decisions and why

**The checks run with the server's Nix.** The dev shell includes
`nixosConfigurations.nuc.config.nix.package`, so `nix` inside `nix develop` is
the exact version comin will evaluate with on the server (2.34.8 as of
2026-09-27). The CI log's "Nix versions" step prints both. See the amendment to
ADR (Architecture Decision Record) 0007.

**Upstream Nix via `cachix/install-nix-action`, not Determinate's installer.**
The installed Nix only starts the dev shell and builds. The ticket named
`DeterminateSystems/nix-installer-action`, which now installs Determinate Nix by
default and calls upstream Nix unsupported and possibly removed later. The
upstream installer keeps third-party distributions out of the pipeline that
gates the server.

**No extra binary cache.** The ticket also named `magic-nix-cache-action`. A
dry run of the closure against an empty store shows 628 paths fetched from
cache.nixos.org (1.2 GiB) and only 36 derivations built locally, all of them
configuration glue (`/etc` entries, systemd units, the initrd). A cache would
save building those, which takes seconds. Revisit if a run takes more than about
ten minutes, for example once the config pulls in a package that is not cached
upstream. To repeat the measurement:

```sh
nix build --dry-run --store "$(mktemp -d)" --option substituters https://cache.nixos.org \
  '.#nixosConfigurations.nuc.config.system.build.toplevel'
```

**Actions pinned by commit hash.** `uses: owner/action@<40-character hash> #
vX.Y.Z`. A tag can be moved to point at different code after it was reviewed; a
commit hash cannot. Bumping an action means looking up the new release's commit
and updating both the hash and the comment.

**Read-only token.** `permissions: contents: read`. The repo is public, anyone
can open a PR, and the job never needs to write. The workflow uses
`pull_request`, never `pull_request_target`, which would run fork code with the
repository's secrets.

**Newer pushes cancel older runs** of the same branch (`concurrency`), so a
quick fix-up does not queue behind a doomed run.

## Not covered

- **`just vm-secrets`.** It needs the private VM test key, which lives only on
  the workstation. Providing it as a repository secret would not reach PRs from
  forks anyway. Run it locally when touching secrets.
- **Hardware.** CI builds the configuration; it cannot tell whether it boots on
  the NUC.
