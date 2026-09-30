# ADR 0006: Rootful Docker as the container runtime, with its risks handled explicitly

Date: 2026-09-29. Status: accepted.

## Context

ADR (Architecture Decision Record) 0002 settled on Compose stacks wrapped in
systemd units, and ticket 3.1 (#22) needs a runtime before the first container
exists. The choice is cheap to make now and expensive later: moving between
runtimes, or into rootless mode, means changing the ownership of every data
directory under `/srv/data`.

Versions on the pinned `nixos-26.05` branch when this was decided: Docker
29.7.2, Docker Compose 5.4.0, Podman 5.8.6, podman-compose 1.5.0, cAdvisor
0.56.2. NixOS itself defaults `virtualisation.oci-containers` to Podman, so
Docker is not the platform's default either.

Three options were compared:

- **A. Docker, rootful.** A root daemon runs the containers; `docker compose`
  drives them. What every game server image documents.
- **B. Podman, rootful**, with its Docker-compatible socket so the real
  `docker compose` can drive it. Daemonless, but still root, so it keeps
  Docker's exposure while adding translation friction.
- **C. Podman, rootless.** Containers run under an unprivileged user; root in a
  container is an unprivileged user on the host. The real security argument
  for Podman.

What mattered for this server:

| | A. Docker | B. Podman rootful | C. Podman rootless |
|---|---|---|---|
| Compose files used unchanged (ADR 0002) | Yes | Nearly all, via the socket | Mostly; `podman-compose` is a reimplementation |
| Compromised game server | Root daemon; `docker` group is root-equivalent | Same as A | Contained to an unprivileged user |
| Published ports vs the NixOS firewall | Bypass it | Bypass it | Ordinary sockets; the firewall applies |
| Per-stack `MemoryMax` / `CPUWeight` (ticket 4.5) | Set on the stack's system unit | Same | Needs systemd delegation under a user manager |
| Declaring it in NixOS | `virtualisation.docker` | `virtualisation.podman` + `dockerSocket` | Lingering user, subordinate ID ranges, user units; Quadlet (Podman's systemd-native units) has no NixOS option in 26.05 |
| cAdvisor (ticket 3.4) | First-class | Supported | Weakest |
| K3s later (Phase 8) | Irrelevant: K3s uses containerd | Same | Same |

The firewall row is the one that is easy to miss. Docker publishes a port by
rewriting incoming traffic with DNAT (destination network address translation)
before it reaches the INPUT chain where NixOS keeps its rules. The packets then
take the FORWARD chain to the container. A default-deny firewall never sees
them, so `ports: ["3000:3000"]` in a compose file is reachable from the LAN
(local area network) even though NixOS never opened port 3000.

## Decision

Run **rootful Docker** (option A), configured through `virtualisation.docker`.
Rootful Podman (B) gives up Docker's compatibility without removing its root
exposure. Rootless Podman (C) is the rejected alternative: it would cost the easy
per-stack resource limits, first-class monitoring, a declaration that is only a
few lines, and some compose fidelity. That friction would land in exactly the
phases where the server starts being used.

`userns-remap`, which maps container root onto an unprivileged ID range while
keeping the rootful daemon, is also **off**. Most game images already drop to an
unprivileged user inside the container, and the measures below cover the likely
risks. It is recorded here because, like rootless mode, it is cheap to enable
only before data exists.

Docker's two risks, the firewall bypass and the root daemon, are handled with
defaults that fail closed and checks that can fail, not with conventions to
remember.

**Published ports**

1. **Loopback by default.** `virtualisation.docker.daemon.settings.ip =
   "127.0.0.1"`. A port published without an address binds to the server alone.
   Exposing one to the network takes an explicit `0.0.0.0:<port>:<port>`, so
   forgetting closes a port instead of opening it.
2. **Public ports declared once, in Nix.** The compose-stack module (ticket 3.2,
   #23) takes each stack's public ports as an option and opens exactly those in
   `networking.firewall`. The firewall configuration then stays a true list of
   what is exposed, even though Docker's traffic does not pass through it.
3. **A flake check compares the two.** It fails `just check`, and so CI
   (continuous integration), if a compose file publishes a port on all
   interfaces that its stack does not declare, uses `network_mode: host`, or
   mounts the Docker socket.
4. **A VM (virtual machine) test proves it end to end.** A two-machine NixOS
   test: the server runs a container publishing one declared port and one
   undeclared port, and a client must reach the first and be refused by the
   second, over IPv4 and IPv6. The negative control is to remove the `ip`
   setting and watch the test fail.
5. **Admin interfaces stay on loopback.** Grafana, Open WebUI and anything else
   admin-facing binds to `127.0.0.1` and is published to the tailnet with
   Tailscale Serve, not bound to the Tailscale address. At boot, Docker can
   start a container before `tailscale0` has that address, and the bind fails.

**The root daemon**

6. **Nobody is in the `docker` group.** Membership is root without a password.
   Stacks run as systemd units, and interactive use goes through `sudo docker`.
7. **No container gets the Docker socket**, read-only or otherwise: read-only
   does not stop API calls. Enforced by the check in 3. Monitoring is the usual
   reason for mounting it, so cAdvisor and node-exporter run as native NixOS
   services, not containers.
8. **`no-new-privileges` daemon-wide**, so a setuid binary inside a container
   cannot gain privileges. A stack whose image needs otherwise opts out in its
   compose file, visibly in review.
9. **Per-image hardening** (`cap_drop: [ALL]`, `read_only`, a non-root `user:`)
   is applied stack by stack where the image tolerates it, and audited in the
   security review (7.2, #45).

## Consequences

- Upstream compose files and documentation apply as written, apart from
  explicit bind addresses on public ports.
- Tickets 3.1 (#22) and 3.2 (#23) carry the implementation: 3.1 the daemon
  settings and the VM test, 3.2 the public-port option and the flake check, each
  with its own negative control.
- ADR 0005's "admin surfaces listen only on the Tailscale interface" is met
  through loopback plus Tailscale Serve. See the note added there.
- A container escape, or a malicious image, yields root on the host. The
  measures above narrow the ways in; they do not change that outcome. This is the
  cost accepted in exchange for the friction avoided.
- Container logs go to journald, the NixOS default for Docker, so log retention
  is journald's `SystemMaxUse`, not Docker's `log-opts`.
- `live-restore`, which keeps containers running while the daemon restarts, is
  off by default in NixOS 26.05. Whether to turn it on is left to ticket 3.1,
  after testing how it behaves across a comin deploy and a reboot.
- **Revisit** (a new ADR, not an edit) if any of these happen:
  - the security review (7.2, #45) finds a stack that cannot be hardened
    acceptably;
  - a stack must run untrusted code, such as user-uploaded plugins;
  - rootless Podman gains NixOS-native Quadlet support and cAdvisor parity.

  Switching then means migrating data-directory ownership stack by stack.
