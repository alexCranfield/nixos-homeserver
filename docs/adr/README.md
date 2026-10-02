# Architecture Decision Records

Each ADR (Architecture Decision Record) records one decision: the context that
forced it, what was decided, and the consequences accepted with it. They are
settled once accepted. If one turns out to be wrong, file an issue and amend
it, or supersede it with a new ADR, rather than editing it quietly (see
`CLAUDE.md`).

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-nixos.md) | NixOS 26.05 with the whole system in a flake; latest kernel for Panther Lake | Accepted |
| [0002](0002-compose-not-k8s.md) | Docker Compose stacks as systemd units; Kubernetes deferred to Phase 8 | Accepted |
| [0003](0003-pull-deploy-comin.md) | GitHub-hosted CI (continuous integration) validates; the server pulls `main` with comin | Accepted |
| [0004](0004-secrets-sops.md) | Secrets encrypted with sops and age, decrypted by sops-nix on the host | Accepted |
| [0005](0005-tailscale.md) | Admin access over Tailscale only; router forwards game ports alone | Accepted |
| [0006](0006-docker-vs-podman.md) | Rootful Docker, with published ports and the root daemon handled by fail-closed defaults and checks | Accepted |
| [0007](0007-nix-distribution-policy.md) | Match flake inputs, not Nix versions; the dev shell carries the server's Nix | Accepted, amended 2026-09-27 |
| 0008 | K3s or stay on Compose | Reserved: ticket 8.1 (#49) |
| 0009 | Disk encryption on the nuc | Reserved: ticket 1.0 (#57), before partitioning |
| 0010 | Security posture | Reserved: ticket 7.2 (#45) |

Numbers are claimed by the ticket that will write the ADR, which is why the
sequence can run ahead of what exists. `docs/PLAN.md` lists the open decisions
and the ticket each must precede.

New ADRs follow the existing shape: a title stating the decision, a
`Date: … Status: …` line, then Context, Decision and Consequences sections.
