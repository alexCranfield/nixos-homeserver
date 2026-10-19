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
the nuc system closure, `nix fmt -- --ci`, and `editorconfig-checker`, which
holds every file git does not ignore to `.editorconfig` (line endings, final
newline, trailing whitespace, tabs). That includes untracked files, so a stray
scratch file in the tree fails `just check` locally until it is removed or
ignored. The workflow does not restate
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
- **Running outside the dev shell.** With a globally installed `just`, or a
  stale direnv cache, `nix` is the workstation's Determinate Nix rather than the
  server's version. `nix develop -c just check` matches CI exactly.
- **Formatting.** `just fmt`, commit, push.

### A VM test that fails before Linux starts, on the workstation

On the workstation, `disk-tpm` often fails before the kernel prints anything
(#80). The VM's console shows one of three forms after `starting vm`:

- an exception from the firmware: `!!!! X64 Exception Type - 0E(#PF -
  Page-Fault)`, or `0D(#GP …)` or `06(#UD …)`;
- no output at all;
- the systemd-boot menu, then nothing.

The test then fails with `neither a prompt nor a boot` or a timeout, in
whichever subtest booted the VM. **This is the workstation, not the change
under test.** Rerun that one test under software emulation:

```sh
just vm-test-tcg disk-tpm
```

It takes about ten minutes instead of three, and its result counts. CI has not
hit this failure.

**The cause.** The workstation's KVM is nested: it runs inside WSL2's own
virtual machine on Hyper-V, with WSL kernel 5.15.167 and an AMD processor
(`kvm_amd`). Firmware run on it crashes or hangs at random, and most often when
the firmware uses SMM (System Management Mode) and talks to a TPM (Trusted
Platform Module). `disk-tpm` exists to test exactly those two things.
`scripts/firmware-boot-loop.sh` boots the test's firmware, with no disk, over
and over. Healthy firmware reaches its shell in about three seconds. Twenty
boots per row, 2026-10-18 and 19:

| Setup | Failed |
|---|---|
| As the test runs it: KVM, OVMF (Open Virtual Machine Firmware) with SMM, TPM | 14 (11 hung, 3 crashed) |
| Same, `-cpu host` instead of `-cpu max` | 13 |
| KVM, SMM, no TPM | 4 (crashed) |
| KVM, no SMM, TPM | 3 (hung) |
| KVM, SMM, TPM, `-machine kernel-irqchip=split` | 5 (crashed) |
| KVM, no SMM, TPM, `kernel-irqchip=split` | 1 (crashed) |
| KVM, no SMM, no TPM | 0 |
| **As the test runs it, but TCG (software emulation) instead of KVM** | **0** |

The same firmware and devices are clean once KVM is out of the path, so neither
OVMF, swtpm nor the NixOS configuration is at fault. None of the QEMU options
above makes KVM reliable, and turning off SMM or the TPM would remove what the
test checks, so the test is left as it is. The full test under TCG passed all
ten subtests in 618 seconds.

To measure the rate again, for example after a WSL update:

```sh
scripts/firmware-boot-loop.sh 20 kvm    # exits non-zero if any boot failed
scripts/firmware-boot-loop.sh 20 tcg    # the control
```

The rate varies from day to day: about one run in three failed on 2026-10-17
and about half on 2026-10-18, with the same code.

## Decisions and why

**The checks run with the server's Nix.** The dev shell includes `pkgs.nix`,
which is what NixOS defaults `nix.package` to, so `nix` inside `nix develop` is
the exact version comin will evaluate with on the server (2.34.8 as of
2026-09-27). The flake check `devshell-nix-matches-server` fails if a host ever
overrides `nix.package`, so the two cannot drift silently. The CI log's "Enter
dev shell" step prints both versions. See the amendment to ADR (Architecture
Decision Record) 0007.

That step is also the first to evaluate `flake.nix`, so a syntax error in
`flake.nix` itself fails there. Errors in `hosts/` or `modules/` fail inside
`just check`, with the `nix flake check` log.

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

**VM (virtual machine) tests run in CI.** Since #10, `nix flake check` also runs
`base-ssh`, a NixOS test that boots two VMs and logs in over SSH. NixOS tests
require the `kvm` system feature. `install-nix-action` provides it on GitHub's
Linux runners (`enable_kvm`, on by default; the job log shows "Enabled KVM"),
and with it the test takes about 25 seconds; the first run, on #71, finished in
under two minutes in all. If the build instead stops because no machine has the
`kvm` and `nixos-test` features, the runner lost KVM (Kernel-based Virtual
Machine) access; the test itself is not at fault. Locally, without KVM access,
the test falls back to software emulation and takes about four minutes;
`docs/runbooks/workstation.md` has the udev rule that fixes that.

**Actions pinned by commit hash.** `uses: owner/action@<40-character hash> #
vX.Y.Z`. A tag can be moved to point at different code after it was reviewed; a
commit hash cannot. Bumping an action means looking up the new release's commit
and updating both the hash and the comment.

**Read-only token.** `permissions: contents: read`. The repo is public, anyone
can open a PR, and the job never needs to write. The workflow uses
`pull_request`, never `pull_request_target`, which would run fork code with the
repository's secrets.

**Newer pushes cancel older runs** of the same pull request (`concurrency`), so
a quick fix-up does not queue behind a doomed run. Each commit on `main` runs in
its own concurrency group and is never cancelled, so every commit there keeps a
result. (A shared group would not be enough: GitHub keeps one pending run per
group and silently cancels the older one.)

**No token left behind.** `actions/checkout` runs with
`persist-credentials: false`, so the job token is not written into `.git/config`
where the pull request's code could read it.

## Not covered

- **`just vm-secrets`.** It needs the private VM test key, which lives only on
  the workstation. Providing it as a repository secret would not reach PRs from
  forks anyway. Run it locally when touching secrets.
- **Hardware.** CI builds the configuration; it cannot tell whether it boots on
  the NUC.
