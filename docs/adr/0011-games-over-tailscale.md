# ADR 0011: Friends reach game servers over Tailscale sharing; nothing is public

Date: 2026-10-24. Status: accepted.

## Context

ADR (Architecture Decision Record) 0005 put admin access on Tailscale and had
the router forward the game ports (Minecraft TCP, Transmission Control
Protocol, 25565; Palworld UDP, User Datagram Protocol, 8211; Satisfactory
7777), so friends could play without installing anything. The
compose-stack module (ticket 3.2, #23) built the enforcement for those public
ports: a declared list, an nftables table that drops anything else Docker
publishes, and a flake check.

Planning the first game server (4.1, #28) raised what a public game port
still exposes. The game's own whitelist and `online-mode` keep strangers out
of the game, but not away from the server software. Internet scanners probe
well-known game ports constantly, and an exploit in the server that runs
before login would reach the nuc. An IP allowlist would stop them, but
friends' home addresses change, and some share one address with other
customers of their provider, so the list would lock friends out unpredictably.

Alex's friends play on PCs, phones and a Steam Deck; none on a console. All of
those can run Tailscale. On a Steam Deck that takes a one-time install from
Desktop Mode, since SteamOS has a read-only system, and depending on the
install method it may need redoing after a SteamOS update.

## Decision

1. **No router port forwards.** Nothing on the nuc is reachable from the
   internet.
2. **Friends reach the game servers through Tailscale's machine sharing.**
   Alex shares the nuc with each friend's Tailscale account; the friend
   installs Tailscale, accepts the invite, and connects to the nuc's tailnet
   name.
3. **Share recipients reach the game ports, not SSH or admin interfaces.**
   The tailnet's access policy allows them the declared game ports on the
   nuc and nothing else it controls. Alex's own devices get the game ports
   too, since the LAN path is closed to games (4, below). One thing the
   policy cannot close: sharing makes each friend's device a peer of the
   nuc, and `tailscaled` answers its peer API (application programming
   interface) to any peer, checking each request against the asking device's
   permissions itself (`docs/runbooks/tailscale.md`). A VM (virtual machine)
   test shows a device limited by the same rule reaches a game port and not
   port 22; Headscale, which the VM tests use in place of Tailscale's
   service, has no machine sharing, so the real share is checked once on the
   live tailnet.
4. **Game ports keep the public-port machinery of ADR 0006, on the tailnet
   interface.** A game stack publishes its ports on `0.0.0.0` and declares
   them in Nix; the `stack-ports` table admits them from `tailscale0` only,
   not from the LAN (local area network) port. Tailscale Serve is not used
   for games: it forwards TCP only (as of 2026-10), and Palworld and
   Satisfactory need UDP.
   The module gains a per-port choice of interface for this (ticket 4.0).
5. **Each game's own access control stays on**, such as Minecraft's whitelist
   and `online-mode`, since everyone with a share can reach every game port.

This applies to every game server: Minecraft, Palworld, Satisfactory and any
added later.

## Consequences

- The nuc has no public attack surface. A flaw in a game server can be
  reached only by people Alex has shared the nuc with.
- Every friend installs Tailscale once and has it running while playing. On a
  phone it takes the single VPN (virtual private network) slot, so it cannot
  run beside another VPN. On a Steam Deck the install is a terminal job in
  Desktop Mode, which a friend may need talking through. The runbook covers
  each device.
- Consoles cannot run Tailscale, so a friend on a console cannot play. If one
  needs to, that is a new decision (a new ADR), not an exception.
- Alex manages the shares and the access policy, and is the first contact
  when a friend cannot connect; the usual cause is Tailscale being off.
- A Tailscale outage stops games as well as admin access. The servers keep
  running; nobody can reach them until it is back.
- Tailscale's plans limit sharing, and the limits have changed over time.
  Ticket 4.0 checks them against the number of friends before relying on them.
- Game ports stay IPv4 only (ADR 0006). The nuc's tailnet name also
  resolves to an IPv6 address, so a game client that prefers IPv6 times out;
  such a friend connects to the nuc's `100.x` address instead. Ticket 4.0
  checks each game's client.
- The router needs no forwards, so its port-forwarding support (`docs/PLAN.md`,
  hardware assumptions) is no longer used.
- ADR 0005's "friends do not need Tailscale" and "game server ports are the
  only public attack surface" no longer hold; a dated note there points here.
  ADR 0006's rules stand for game ports: declared once, IPv4 only, enforced by
  the firewall and the check.
