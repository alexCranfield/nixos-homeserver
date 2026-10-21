# Runbooks

Operational procedures, written as tickets are completed.

## Written

- [workstation.md](workstation.md) — Nix and direnv on the WSL workstation (ticket 0.1)
- [secrets.md](secrets.md) — sops, age, key locations, adding a secret (ticket 0.5)
- [ci.md](ci.md) — what CI runs, why, and what to do when it is red (ticket 0.4)
- [network.md](network.md) — the LAN port, the router's reservation and name, the firewall (ticket 1.4)
- [tailscale.md](tailscale.md) — the tailnet, the auth key, joining devices, SSH over Tailscale (ticket 1.5)
- [reinstall.md](reinstall.md) — any install since 1.7: the host key made on the workstation, the smoke tests (ticket 1.8)
- [install.md](install.md) — installing the nuc with nixos-anywhere, the disk passphrase, the TPM key (ticket 1.6)
- [updates.md](updates.md) — the weekly `flake.lock` pull request, the reboot window, pausing comin (tickets 2.2 and 2.3)
- [notifications.md](notifications.md) — what posts to Discord, the webhook and role secret, a test failure (ticket 2.5)
- [deploy.md](deploy.md) — comin pulling `main`, checking it, the manual deploy (ticket 2.1)
- [hardware.md](hardware.md) — the live USB, assembly, BIOS settings and the hardware survey (ticket 1.1; the record fills in when it closes)

## Planned

Not yet written. Each arrives with the ticket named.

- `data-layout.md` (ticket 3.3) — `/srv/data` conventions and ownership
- `game-ops.md` (ticket 4.4) — broadcasts, restarts, restoring a world
- `new-game-server.md` (ticket 4.6) — adding another game
