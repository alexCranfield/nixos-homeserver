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

## Documents

- [docs/PLAN.md](docs/PLAN.md): the phased build plan. Each ticket is a GitHub Issue under a phase milestone.
- [docs/adr/](docs/adr/): architecture decision records.
- [docs/runbooks/](docs/runbooks/): operational procedures, added as phases complete.

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
