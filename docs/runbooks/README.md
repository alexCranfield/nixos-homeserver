# Runbooks

Operational procedures, written as tickets are completed.

## Written

- [workstation.md](workstation.md) — Nix and direnv on the WSL workstation (ticket 0.1)
- [secrets.md](secrets.md) — sops, age, key locations, adding a secret (ticket 0.5)
- [ci.md](ci.md) — what CI runs, why, and what to do when it is red (ticket 0.4)
- [network.md](network.md) — the LAN port, the router's reservation and name, the firewall (ticket 1.4)
- [tailscale.md](tailscale.md) — the tailnet, the auth key, joining devices, SSH over Tailscale, sharing the nuc with a friend (tickets 1.5 and 4.0)
- [reinstall.md](reinstall.md) — any install since 1.7: the host key made on the workstation, the smoke tests (ticket 1.8)
- [install.md](install.md) — installing the nuc with nixos-anywhere, the disk passphrase, the TPM key (ticket 1.6)
- [updates.md](updates.md) — the weekly `flake.lock` pull request, the reboot window, pausing comin (tickets 2.2 and 2.3)
- [notifications.md](notifications.md) — what posts to Discord, the webhook and role secret, a test failure (ticket 2.5)
- [rollback.md](rollback.md) — undoing a bad change: revert on GitHub, the boot menu, what CI catches (ticket 2.4)
- [deploy.md](deploy.md) — comin pulling `main`, checking it, the manual deploy (ticket 2.1)
- [docker.md](docker.md) — rootful Docker: `sudo docker`, ports on loopback by default, logs, prune, storage (ticket 3.1)
- [stacks.md](stacks.md) — Compose stacks as units: adding one, public ports and their log, what the check rejects, crash alerts (ticket 3.2)
- [data-layout.md](data-layout.md) — `/srv/data/<stack>` subvolumes, the ID convention, the nightly snapshot, `just snapshot` and `just rollback` (ticket 3.3)
- [game-access.md](game-access.md) — for friends: installing Tailscale (Steam Deck included), accepting the share, connecting, "can't connect?" (ticket 4.0)
- [hardware.md](hardware.md) — the live USB, assembly, BIOS settings and the hardware survey (ticket 1.1; the record fills in when it closes)

## Planned

Not yet written. Each arrives with the ticket named.

- `game-ops.md` (ticket 4.4) — broadcasts, restarts, restoring a world
- `new-game-server.md` (ticket 4.6) — adding another game
