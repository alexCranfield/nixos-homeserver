# Containers and Docker

### What does Podman offer over Docker, and what would it cost on this server?

*2026-09-29*

> yes, lay out the Docker vs Podman trade-offs

<details>
<summary>Answer</summary>

There are three real options, not two, because Podman can run either as root or
rootless.

- **Docker, rootful.** A root daemon runs every container, and `docker compose`
  drives it. Every game server image documents itself this way.
- **Podman, rootful.** No daemon, and a Docker-compatible socket lets the real
  `docker compose` drive it. But it still runs as root, so it keeps Docker's
  exposure and adds translation friction. It is not a middle ground.
- **Podman, rootless.** Containers run as an unprivileged user, and root inside
  one is nobody on the host. This is the actual security argument for Podman.

What rootless would cost here:

- Per-stack `MemoryMax` and `CPUWeight` (ticket 4.5) are easy on a system unit.
  Rootless, they live on user units under that user's own systemd manager,
  away from the rest of the system's declarations.
- The NixOS declaration grows from a few lines to a lingering user,
  subordinate user-ID ranges and per-user units. Quadlet, Podman's
  systemd-native unit format, has no NixOS option in 26.05.
- cAdvisor sees rootless containers worst of all.
- `podman-compose` reimplements Compose, so upstream files are less likely to
  work unchanged.

Two things were not problems: players' real IP addresses survive rootless
networking with pasta, and K3s (Phase 8) uses containerd whichever runtime is
chosen.

The decisive point is timing. Rootless mode is cheap to choose before any data
exists and expensive afterwards, because rootless containers write files under
shifted user IDs. Every data directory would need migrating.

Decision: rootful Docker. See ADR (Architecture Decision Record) 0006.

</details>

### How do we handle the risks of running Docker as root?

*2026-09-29*

> I think docker makes sense, but please explain how we can handle the risk
> explicitly

<details>
<summary>Answer</summary>

There are two risks. The principle for both: a default that fails closed, a check
that CI (continuous integration) runs, and a test that proves the check can fail.

**Published ports bypass the firewall.** Docker publishes a port by rewriting
incoming packets with DNAT (destination network address translation) before they
reach the INPUT chain, which is where NixOS keeps its firewall rules. The packets
then take the FORWARD chain to the container, so a default-deny firewall never
sees them. `ports: ["3000:3000"]` is reachable from the LAN (local area network)
even though NixOS never opened 3000.

1. Make the default safe: bind any port published without an address to
   loopback. Exposing one then takes an explicit `0.0.0.0:`, so forgetting
   closes a port instead of opening it. Docker keeps this default in two
   places:
   - the `ip` daemon setting covers only the built-in `bridge` network;
   - `default-network-opts` covers the networks Compose creates.

   The first version of this answer named only `ip`. Review of the Docker
   source caught it, and it would have left every stack open. That is the case
   for step 4.
2. Declare public ports once, in Nix, per stack, and open exactly those in the
   firewall. The firewall configuration becomes a true list of what is exposed.
3. A flake check fails if a compose file publishes a port without naming its
   host address, publishes an undeclared port on all interfaces, overrides the
   network's default address, uses host networking, or mounts the Docker
   socket.
4. A two-machine NixOS VM (virtual machine) test, deploying a real stack
   through Compose: a client must reach the declared port and fail to reach the
   undeclared one. It times out rather than being refused, because NixOS drops
   packets. Remove the network default and the test must fail. That is the
   negative control.
5. Admin interfaces stay on loopback, and Tailscale Serve publishes them to the
   tailnet. Binding to the Tailscale address instead can fail at boot, because
   Docker may start before `tailscale0` has its address.

**The daemon is root.**

- Nobody joins the `docker` group, because membership is root without a
  password. Use `sudo docker`.
- No container gets `/var/run/docker.sock`. Mounting it read-only does not help:
  `:ro` stops writes to the socket file, not API (application programming
  interface) calls through it. Monitoring is
  the usual excuse, so cAdvisor and node-exporter run as native NixOS services.
- `no-new-privileges` daemon-wide stops setuid binaries and file capabilities
  escalating inside a container. Entrypoints that drop from root with `gosu`
  still work.
- `cap_drop`, `read_only` and non-root users are applied stack by stack in the
  security review.

What this does not change: a container escape still yields root. The measures
narrow the ways in. That residual risk is the accepted cost of Docker's
simplicity.

`userns-remap` was the middle option. It maps container root to an unprivileged
ID range while keeping the rootful daemon. It was left off because most game
images already drop to an unprivileged user, and it shares rootless mode's
"cheap only before data exists" property.

</details>

### How likely is Docker to fail, and is Grafana safer in a container?

*2026-10-27*

> Native is fine, that makes sense, but realistically how likely is docker going to fail? Is it safer to have it containerised?

<details>
<summary>Answer</summary>

Docker failing outright is unlikely. The realistic ways it stops the containers
are rarer events: the daemon restarting for a Docker update (which arrives
through the weekly `flake.lock` bump) or for a daemon setting that needs a start
with nothing running (ADR (Architecture Decision Record) 0006); Docker's
storage filling up or getting corrupted, since it shares the one btrfs
filesystem with everything else; and a bad image or Compose change the checks
don't catch.

The argument for running Grafana natively is overlap rather than probability:
monitoring shouldn't fail for the same reasons as the things it watches. In
Docker, a Docker problem takes out the dashboard you'd use to look into it.
Prometheus and the exporters are native for the same reason.

On safety, a container adds little here. The nixpkgs Grafana module runs it as
its own user with systemd's sandboxing, about what rootful Docker gives a
container. Native Grafana also gets security updates through the `flake.lock`
bump, with no image tag to pin and follow.

</details>

### Are there alerts for containers, such as a Minecraft container that is under-provisioned?

*2026-10-28*

> do you have alerts for containers, say if the minecraft container is under-provisioned?

<details>
<summary>Answer</summary>

Yes, four, and they watch the stack rather than the single container, because
limits are set per stack (`stack-<name>.slice`), not per container:

- `StackMemoryNearLimit`: the stack's memory is above 90 % of its own
  `memoryMax` for 15 minutes. This is the "about to be killed" warning.
- `StackMemoryStalled` and `StackCpuStarved`: processes in the stack wait for
  memory (10 % of the time) or for a core (25 %). These use the kernel's
  pressure stall information (PSI), which shows a stack that is short of a
  resource before it hits a hard limit, and also a stack with no limit that
  the host as a whole is squeezing.
- `OomKill`: the kernel killed a process for lack of memory in a named
  container. This is an event, so it posts at once.

A fifth, `ContainerCpuHigh`, catches one container taking more than 75 % of
the whole host's CPU for 15 minutes.

What they cannot see is inside the game: the server falling behind its 20
ticks per second, or Java's heap running short while the container's memory
looks fine. Those need the Minecraft exporter, so they are added to #168.
Minecraft idles at about 84 % of its 18G limit (measured 2026-10-28), close
enough to the 90 % line that the first week's noise review matters. The
thresholds are in [the observability runbook](../runbooks/observability.md#alerts).

</details>
