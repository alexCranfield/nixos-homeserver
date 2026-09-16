# nixos-homeserver

Declarative NixOS configuration for a home server on an ASRock Industrial NUC BOX-358H
(Intel Core Ultra X7 358H, 96 GB DDR5, 1 TB NVMe). It runs Docker Compose game servers
(Minecraft, Palworld, Satisfactory), local LLMs (Ollama + Open WebUI) and development
shells for Shopify admin scripting.

## How it works

```
pull request ──▶ GitHub Actions: nix flake check, build closure, fmt
merge to main ──▶ comin on the server polls, runs nixos-rebuild switch
```

The server is installed from this repo with `nixos-anywhere` and `disko`, updates itself
from `main`, backs up to the NAS (network-attached storage) with restic, and is reachable for admin only over Tailscale.

## Layout

```
flake.nix                          inputs, nixosConfigurations.nuc, formatter, checks
flake.lock                         pinned revisions; commit every change
hosts/nuc/default.nix              the host: imports hardware + base
hosts/nuc/hardware-configuration.nix   PLACEHOLDER until the machine exists
modules/base/default.nix           config applied to every host
modules/dev/vm-secrets.nix         test-only: proves sops-nix decrypts in a VM
.sops.yaml                         which age keys can decrypt which files
secrets/                           sops-encrypted secrets; ciphertext only
scripts/tickets.py                 ticket definitions; file_issues.py files them
```

Build the whole system without a machine:

```bash
nix flake check                                                    # evaluates and builds
nix build .#nixosConfigurations.nuc.config.system.build.toplevel   # the OS as one derivation
nix fmt                                                            # format the tree
```

## Tasks

`direnv` loads the flake's devShell on `cd`, putting `just`, `sops`, `age`,
`ssh-to-age`, `nixos-anywhere` and `nixos-rebuild` on `PATH` at versions pinned
by `flake.lock`. Without direnv, prefix anything below with `nix develop -c`.

| Target | Does |
|---|---|
| `just` | list the targets |
| `just fmt` | format every file in place |
| `just check` | everything CI runs: `nix flake check`, build the closure, check formatting |
| `just build` | build the nuc closure, print its store path |
| `just vm` | boot the nuc config in a local VM; quit with ctrl-a then x |
| `just vm-secrets` | prove sops-nix decrypts in a VM; exits non-zero on failure |
| `just deploy` | emergency manual deploy; normally comin pulls `main` itself |
| `just secrets-edit <file>` | edit an encrypted secret, re-encrypting on save |
| `just secrets-show <file>` | print a secret without opening an editor |
| `just secrets-rekey <file>` | re-encrypt after changing recipients in `.sops.yaml` |

`just check` is the single source of truth for what CI runs, so the workflow in
ticket 0.4 calls it rather than restating the commands. `just vm-secrets` exits
non-zero when decryption fails, because the VM powers off with status 0 either
way and only the console distinguishes them.

Two habits worth keeping. Use `secrets-show` rather than `secrets-edit` when you
only want to look: saving from an editor rewrites the file with a fresh MAC and
timestamp, producing a diff that claims a secret changed when it did not. And
`secrets-rekey` is required after editing `.sops.yaml`; adding a recipient there
does not re-encrypt anything on its own.

## Documents

- [docs/PLAN.md](docs/PLAN.md): the phased build plan. Each ticket is a GitHub Issue under a phase milestone.
- [docs/adr/](docs/adr/): architecture decision records.
- [docs/runbooks/](docs/runbooks/): operational procedures, added as phases complete.
- [docs/learning.md](docs/learning.md): reading list, sequenced against the phases.
- [docs/q-and-a/](docs/q-and-a/): questions asked during the build, with answers, kept for revision.

## Status

Phase 0 (workstation and repo foundations) in progress. See the
[milestones](https://github.com/alexCranfield/nixos-homeserver/milestones).

## License

GPL-3.0. See `LICENSE`.

## Filing the tickets

`scripts/tickets.py` holds every ticket from the plan. To create the milestones, labels and
issues (idempotent, safe to re-run):

```
GITHUB_TOKEN=<token with Issues: write> python3 scripts/file_issues.py
```
