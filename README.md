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
scripts/tickets.py                 ticket definitions; file_issues.py files them
```

Build the whole system without a machine:

```bash
nix flake check                                                    # evaluates and builds
nix build .#nixosConfigurations.nuc.config.system.build.toplevel   # the OS as one derivation
nix fmt                                                            # format the tree
```

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
