# ADR 0005: Tailscale for admin access, port forwards only for game traffic

Date: 2026-09-07. Status: accepted.

## Context
Friends need to reach game servers from the internet. The owner needs SSH, Grafana and the LLM (large language model) UI from anywhere. Exposing SSH or web UIs publicly means reverse proxies, TLS (Transport Layer Security), fail2ban and ongoing patch pressure.

## Decision
Join the server to a Tailscale tailnet. SSH, Grafana, Open WebUI and any future admin surface listen only on the Tailscale interface. The router forwards only the game ports (Minecraft TCP 25565, Palworld UDP 8211, Satisfactory 7777) to the server. The firewall is default deny.

## Consequences
- No public SSH, so no fail2ban and no key-scanning noise.
- Friends do not need Tailscale; they use the forwarded game ports.
- A Tailscale outage blocks remote admin; LAN access still works as a fallback.
- Game server ports are the only public attack surface; keep those images updated.
- Note, 2026-09-29 (ADR 0006): Docker's published ports bypass the NixOS
  firewall, so "default deny" does not hold for containers on its own.
  Containerised admin interfaces therefore bind to loopback and reach the
  tailnet through Tailscale Serve, and only ports a stack declares as public
  are exposed. ADR 0006 lists the checks that enforce this.
