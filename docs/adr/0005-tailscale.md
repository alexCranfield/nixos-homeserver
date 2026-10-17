# ADR 0005: Tailscale for admin access, port forwards only for game traffic

Date: 2026-09-07. Status: accepted.

## Context
Friends need to reach game servers from the internet. The owner needs SSH, Grafana and the LLM (large language model) UI from anywhere. Exposing SSH or web UIs publicly means reverse proxies, TLS (Transport Layer Security), fail2ban and ongoing patch pressure.

## Decision
Join the server to a Tailscale tailnet. SSH, Grafana, Open WebUI and any future admin surface listen only on the Tailscale interface. The router forwards only the game ports (Minecraft TCP 25565, Palworld UDP 8211, Satisfactory 7777) to the server. The firewall is default deny.

## Consequences
- No public SSH, so no fail2ban and no key-scanning noise.
- Friends do not need Tailscale; they use the forwarded game ports.
- A Tailscale outage blocks remote admin; LAN (local area network) access still works as a fallback.
- Game server ports are the only public attack surface; keep those images updated.
- Note, 2026-09-29 (ADR 0006): Docker's published ports bypass the NixOS
  firewall, so "default deny" does not hold for containers on its own.
  Containerised admin interfaces therefore bind to loopback and reach the
  tailnet through Tailscale Serve, and only ports a stack declares as public
  are exposed. ADR 0006 lists the checks that enforce this. For those
  interfaces, the "LAN access still works as a fallback" consequence above no
  longer holds; whether SSH keeps a LAN fallback is ticket 1.4's call (#11).
- Note, 2026-10-17 (ticket 1.5, #12): SSH stays OpenSSH, keys only, carried
  over the tailnet; Tailscale SSH is not used, so a login still needs the ops
  key. Only port 22 is open on `tailscale0`, rather than trusting the whole
  interface; 22 also stays open on the LAN until ticket 1.7 (#14), when the
  nuc can decrypt its auth key and join the tailnet unattended, and is then
  removed: no permanent LAN fallback for SSH. So if the tailnet is down,
  getting in means a monitor and keyboard on the nuc. The nuc joins with a
  single-use auth key tagged `tag:server`.
- Note, 2026-10-17 (ticket 1.5, #12): the NixOS firewall does not cover
  everything on the tailnet. `tailscaled` answers its peer API port, and
  Tailscale SSH and Serve ports when enabled, inside its own network stack,
  before the kernel's firewall. So the tailnet's access policy, not the
  firewall, is what limits who reaches a Serve-published admin interface
  (ADR 0006). The policy therefore replaces Tailscale's default, which lets
  every device reach every other, tagged ones included: the owner's devices
  reach the nuc on 22 only, and the nuc reaches nothing.
  `docs/runbooks/tailscale.md` has the policy; Serve adds its ports to it.
  The peer API is the exception to both: the policy lets every device
  connect to it, and `tailscaled` checks each request against the asking
  device's permissions instead.
