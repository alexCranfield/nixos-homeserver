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
| Per-stack `MemoryMax` / `CPUWeight` (ticket 4.5) | Set on the stack's system unit | Same | Limits live on user units under the user's own systemd manager, outside the system-level declarations |
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

1. **Loopback by default, on every network.** Two daemon settings, because
   Docker keeps the default in two places:
   - `ip = "127.0.0.1"` covers only Docker's built-in `bridge` network, used
     by a bare `docker run`;
   - `default-network-opts.bridge."com.docker.network.bridge.host_binding_ipv4"
     = "127.0.0.1"` covers every bridge network created afterwards, including
     the `<project>_default` network each Compose stack creates for itself.

   A port published without an address then binds to the server alone.
   Exposing one takes an explicit `0.0.0.0:<port>:<port>`, so forgetting
   closes a port instead of opening it. A compose file can still override the
   network option with its own `driver_opts`, which the check in 3 rejects.
   The option is applied only when a network is created, and Compose reuses an
   unchanged network, so a network older than the setting keeps its old
   address. That can only matter if the setting ever changes.
   Public ports are IPv4 only: an explicit `0.0.0.0` does not also bind `[::]`,
   and the router forwards IPv4. Exposing a game over IPv6 would be a separate
   decision.
2. **Public ports declared once, in Nix.** The compose-stack module (ticket 3.2,
   #23) takes each stack's public ports as an option and opens exactly those in
   `networking.firewall`. The firewall configuration then stays a true list of
   what is exposed, even though Docker's traffic does not pass through it.
3. **A flake check compares the two.** It fails `just check`, and so CI
   (continuous integration), if a compose file under `stacks/`:
   - publishes a port without naming its host address;
   - publishes a port on all interfaces that its stack does not declare;
   - sets `host_binding_ipv4` on a network;
   - uses `network_mode: host`;
   - mounts the Docker socket.

   It reads both the short (`"0.0.0.0:25565:25565"`) and long (`host_ip:`) port
   syntaxes, and port ranges.
4. **A VM (virtual machine) test proves it end to end.** A two-machine NixOS
   test that deploys a stack through the compose-stack module, not a bare
   `docker run`, since the two use different networks.
   - The client must reach the declared port over IPv4.
   - It must fail to reach the undeclared one over IPv4 and IPv6. NixOS drops
     rather than rejects by default, so "fail" means a timeout, not a refusal.
   - The undeclared port is published *without* an address, because that is
     the case the default exists for. So the test's compose file lives under
     `tests/`, outside `stacks/` where the check in 3 looks. A fixture that
     named `127.0.0.1` would pass whatever the daemon did.
   - The negative control is to remove `default-network-opts` and watch the
     test fail.
5. **Admin interfaces stay on loopback.** Grafana, Open WebUI and anything else
   admin-facing binds to `127.0.0.1` and is published to the tailnet with
   Tailscale Serve, not bound to the Tailscale address. At boot, Docker can
   start a container before `tailscale0` has that address, and the bind fails.

**The root daemon**

6. **Nobody is in the `docker` group.** Membership is root without a password.
   Stacks run as systemd units, and interactive use goes through `sudo docker`.
7. **No container gets the Docker socket**, read-only or otherwise: read-only
   stops writes to the socket file, not API (application programming
   interface) calls through it. Enforced by the check in 3. Monitoring is the usual
   reason for mounting it, so cAdvisor and node-exporter run as native NixOS
   services, not containers.

   *Note, 2026-10-27 (ticket 3.4, #25):* Grafana runs natively too
   (`services.grafana`), not as the Compose stack the plan first had. The
   dashboards then keep working when Docker is what's broken, which is when
   they're most wanted, and the data source, dashboards and admin password
   come from Nix and sops. A container would add little isolation over the
   nixpkgs module's systemd sandboxing. It is still bound to `127.0.0.1` and
   published with Tailscale Serve (5), over plain HTTP: HTTPS would put the
   tailnet's name in the public Certificate Transparency logs (#163).
8. **`no-new-privileges` daemon-wide**, so a process inside a container cannot
   gain privileges through a setuid binary or file capabilities. Entrypoints
   that start as root and drop to a user with `gosu` or `su-exec` still work;
   `sudo` or `su` from a non-root user does not. An image that needs it opts
   out per container with `security_opt: ["no-new-privileges=false"]`, which
   shows up in review.
9. **Per-image hardening** (`cap_drop: [ALL]`, `read_only`, a non-root `user:`)
   is applied stack by stack where the image tolerates it, and audited in the
   security review (7.2, #45).

## Consequences

- Upstream compose files and documentation apply as written, apart from an
  explicit host address on every published port.
- The first draft of this ADR relied on the `ip` setting alone. Review of the
  Docker 29.7.2 source showed that it covers only the built-in `bridge` network,
  so every Compose stack would have published on all interfaces. The two-setting
  default in 1, and a VM test that goes through Compose, both come from that
  finding.
- Tickets 3.1 (#22) and 3.2 (#23) carry the implementation: 3.1 the daemon
  settings, 3.2 the public-port option, the flake check and the VM test, since
  the test deploys through the compose-stack module. Each has its own negative
  control.
- ADR 0005's "admin surfaces listen only on the Tailscale interface" is met
  through loopback plus Tailscale Serve, so containerised admin interfaces have
  no LAN fallback. See the note added there.
- A container escape, or a malicious image, yields root on the host. The
  measures above narrow the ways in; they do not change that outcome. This is the
  cost accepted in exchange for the friction avoided.
- Container logs go to journald, the NixOS default for Docker, so log retention
  is journald's `SystemMaxUse`, not Docker's `log-opts`.
- `live-restore`, which keeps containers running while the daemon restarts, is
  off by default in NixOS 26.05. Whether to turn it on is left to ticket 3.1,
  after testing how it behaves across a comin deploy and a reboot.
- **Note, 2026-10-24 (3.2, #23): limits go on a slice.** The table's "set on
  the stack's system unit" does not work as written. Docker starts containers
  under containerd, not under the unit, so `MemoryMax=` on the unit would
  limit only the `docker compose` client. The compose-stack module puts each
  stack's containers in `stack-<name>.slice`, which carries the limits; the VM
  test shows a container killed for memory at the slice's limit. The
  advantage over rootless Podman stands: the limits are still system-level
  declarations.
- **Note, 2026-10-24 (3.2, #23): the firewall now enforces declared ports.**
  Point 2 says Docker's traffic does not pass through the firewall. Since
  3.1's forward filter it does, on the forward path, and 3.2 adds a
  `stack-ports` table there that drops any connection Docker redirected to a
  port no stack declares, or that arrives anywhere but the LAN port. The
  flake check in 3 and this table are now independent layers; the VM test
  removes each in turn ([stacks.md](../runbooks/stacks.md#public-ports)).
- **Revisit** (a new ADR, not an edit) if any of these happen:
  - the security review (7.2, #45) finds a stack that cannot be hardened
    acceptably;
  - a stack must run untrusted code, such as user-uploaded plugins;
  - rootless Podman gains NixOS-native Quadlet support and cAdvisor parity.

  Switching then means migrating data-directory ownership stack by stack.
- Note, 2026-10-24 (ADR 0011): nothing is forwarded from the router any more;
  game ports are declared for the tailnet interface. Point 1's "the router
  forwards IPv4" no longer applies, but public ports stay IPv4 only: the
  check in 3 and the firewall still enforce it, and ADR 0011 notes the
  tailnet's IPv6 address that game clients may try.
