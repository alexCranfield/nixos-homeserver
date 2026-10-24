# Compose-stack module design (ticket 3.2, #23)

Date: 2026-10-24. Status: for Alex's approval.

## Intent

Every container workload on the nuc deploys the same way: a compose file and
its secrets in this repo become one systemd unit, which comin deploys like
anything else. The first real user is Minecraft (4.1, #28), so the part that
has to be right from day one is **public ports**: the only thing on the nuc
reachable from the internet will be what this module opens.

Agreed order of work around it: this ticket (with its VM test), then the data
layout (3.3, #24), then Minecraft on the LAN only, then backups (3.5, #26),
then the router forward for friends, then Grafana (3.4, #25).

## Goals

1. **One option set per stack** turns a compose file plus a sops env file into
   a systemd service `stack-<name>.service`.
2. **Public ports are declared once, in Nix**, and that declaration is
   enforced in three independent places: the firewall, a flake check over
   `stacks/`, and a VM (virtual machine) test.
3. **A crash at 2 a.m. restarts the container and alerts Discord**: quietly
   for a one-off crash, with a ping if it keeps crashing.
4. **Access attempts on public ports are recorded** in the journal, so later
   tickets can graph and alert on them.
5. **Per-stack resource limits** that actually reach the containers.
6. A `hello` example stack deploys through comin, and `systemctl status
   stack-hello` is active.

## Non-goals

- Grafana dashboards or alert rules over the access log (3.4 #25, 3.6 #27).
- Minecraft itself, its whitelist and `online-mode` (4.1 #28). Alex chose
  the Minecraft whitelist plus `online-mode` over an IP allowlist, because
  friends' home IPs change and some friends cannot run Tailscale.
- The `/srv/data` layout (3.3 #24); `dataDir` is only an option here.
- Updating images. Nothing in the plan covers pulling newer image versions
  yet; file a follow-up issue.
- IPv6 public ports (ADR 0006: a separate decision).

## Anti-goals (failure even if it works)

- A port reachable from the internet that is not declared in Nix.
- A forgotten port opening rather than closing.
- Compose files that stop looking like upstream examples (no Nix-generated
  compose, no required boilerplate in each file).
- An alert storm: one crashing container posting to Discord in a loop.
- Hello exposing anything to the LAN just to show the module works.

## Constraints

- ADR 0006 throughout. In particular: loopback default on every network
  (done in #22); explicit `0.0.0.0:p:p` for public ports; IPv4 only; no
  `network_mode: host`; no Docker socket in any container; nobody in the
  `docker` group; `no-new-privileges` daemon-wide.
- The NixOS forward chain is `policy drop` with `filterForward` (#22,
  `modules/base/firewall.nix`). Docker keeps its own iptables-nft tables
  (`flushRuleset = false`).
- `live-restore` is on (#22): containers survive daemon restarts, so only a
  reboot or a crash stops one.
- The repo's conventions (CLAUDE.md): branch and PR per ticket, evidence and
  negative controls in the PR, runbooks, ADR updates, follow-up issues.
- The flake only sees git-tracked files.

## Design

### Options

`homeserver.stacks.<name>` in `modules/containers/compose-stack.nix`. The
attribute name is the stack name and the Compose project name.

| Option | Type | Meaning |
|---|---|---|
| `composeFile` | path | the stack's `docker-compose.yml`, under `stacks/` |
| `envSecret` | null or sops secret name | the decrypted file becomes the stack's `.env` |
| `publicPorts` | list of `{ port; protocol = "tcp" \| "udp"; allowedSources ? null; }` | ports opened to the LAN interface; see below |
| `dataDir` | null or path | the stack's data directory, normally `/srv/data/<name>`; created if set (owner and subvolume left to 3.3) |
| `resources.memoryMax` | null or string | systemd `MemoryMax=` on the stack's slice |
| `resources.cpuWeight` | null or int | systemd `CPUWeight=` on the stack's slice |
| `after` | list of unit names | extra ordering, e.g. a mount |

Port ranges: `publicPorts` takes single ports; a range is a list of them
(generated with `lib.range`). Builder's call whether to add a range type.

**Data paths (Claude's call).** Compose files name their bind mounts by
absolute path under the stack's `dataDir`, e.g.
`/srv/data/minecraft:/data`, as many upstream examples already do. The
project directory is `/etc/stacks/<name>`, so a relative `./data` would land
under `/etc`: the flake check rejects relative bind-mount sources, and
rejects absolute ones outside the stack's `dataDir` (named volumes stay
allowed). No variable interpolation, so the file reads as written.

Stack declarations live next to their compose files: `stacks/<name>/default.nix`
sets `homeserver.stacks.<name>`, and `hosts/nuc` imports the stacks it runs.

### The unit

`stack-<name>.service`:

- `Wants=` and `After=` `docker.service`, `After=network-online.target`,
  `Wants=network-online.target`, plus `after`. **Not `Requires=`:** a deploy
  that changes Docker restarts `docker.service`, and under `Requires=` that
  would stop the stack unit, whose stop is `docker compose down`, taking every
  game offline. That is what #22's `live-restore` exists to avoid: on a daemon
  restart the stack unit stays active and its containers keep running. The VM
  test covers this (below).
- `Type=oneshot`, `RemainAfterExit=yes`.
- `ExecStart`: `docker compose -p <name> --project-directory /etc/stacks/<name>
  -f compose.yml -f override.yml up -d --remove-orphans --wait`, then the port
  check below. `--wait` (healthy or running) makes a container that exits at
  once fail the unit. Builder: confirm `--wait` behaves for containers without
  a healthcheck on the pinned Compose version, and set `TimeoutStartSec`
  generously for first-time image pulls.
- `ExecStop`: `docker compose ... down`. Volumes are not removed.
- `wantedBy = multi-user.target`, so stacks come up at boot.
- `restartTriggers`: the compose file, the generated override, and the env
  secret's content hash (sops-nix's secret file, via its `restartUnits` or an
  equivalent), so a change to one stack restarts only that stack.
- Listed in `homeserver.notify.units`, so a failed start posts to Discord
  (#20).
- Removing a stack from the configuration stops its unit, which runs `down`.

Files go to `/etc/stacks/<name>/` via `environment.etc`: `compose.yml` (the
stack's file, unchanged), `override.yml` (generated), and `.env` as a symlink
to the sops secret (root-only, never in the store).

### The generated override

The compose file stays as upstream wrote it. The module generates a second
compose file merged by `docker compose -f a -f b`, which sets on every service
in the stack:

- `restart: unless-stopped`, so Docker restarts a crashed container (systemd
  never sees a container die: the unit's process exits after `up -d`);
- `cgroup_parent: stack-<name>.slice`, so the containers run in the stack's
  slice.

To set these per service, the module needs the service names. Builder's call:
read them from the compose file at build time (YAML to JSON in a derivation,
then `builtins.fromJSON` via import-from-derivation, which this repo has not
used so far), or have the stack declare its service names as an option and
let the flake check verify they match. The second avoids import-from-derivation
and is preferred unless it proves awkward.

### Resource limits

**Correction to ADR 0006**, whose table says limits are "set on the stack's
system unit". That would not work: Docker starts containers under containerd,
not under the unit, so `MemoryMax=` on `stack-<name>.service` limits only the
`docker compose` client. Instead the module declares `stack-<name>.slice` with
the limits and the override puts the stack's containers in it with
`cgroup_parent`. This relies on Docker's systemd cgroup driver (the default on
cgroup v2); builder verifies on the pinned Docker (29.9.1) that the container
appears under `stack-<name>.slice` and that `MemoryMax` is enforced. The ADR
gets a dated note under Consequences, not a silent edit.

### Public ports: enforcement in the firewall

Today the NixOS forward chain accepts every new connection Docker has
redirected (`ct status dnat accept`, in NixOS's `forward-allow`), so an
undeclared `0.0.0.0` port would be reachable from the LAN. Only the flake check
would stop it. This design adds the firewall as a real second layer:

- A separate nftables table with a chain on the forward hook, at a priority
  that runs before NixOS's filter chain (e.g. `filter - 10`). A drop in any
  base chain is final, so it cannot be undone by the later accept.
- For new connections with `ct status dnat`:
  - if the original destination port (`ct original proto-dst`) and protocol
    are declared, the packet came in on `lan0`, and `allowedSources` (when
    set) contains the source address: count, log, accept;
  - otherwise: count, log, drop.
- Logs are rate-limited per port (`limit rate`) with a prefix per port, such
  as `stack-port 25565/tcp`, so a scan fills neither the journal nor the
  disk.
- `allowedSources`, off by default (`null` = anyone), restricts a port to the
  listed IPv4 addresses or ranges. Alex chose not to use it for Minecraft; it
  exists so it can be turned on later.
- Declared ports open on `lan0` only, not `tailscale0`: friends come in through
  the router forward, and Alex joins from home on the LAN.
- Loopback-published ports are not affected: they never take the forward
  path (docker-proxy serves them).
- Builder checks: Docker's own hairpin traffic (a container reaching another
  stack's public port through the host's address) arrives on a bridge, not
  `lan0`, and would be dropped. Acceptable; record it in the runbook. Also
  check that nothing else on the nuc relies on DNAT through the forward hook
  (Tailscale does not forward here).

`networking.firewall.interfaces.lan0.allowedTCPPorts`/`UDPPorts` also list the
declared ports, so `nft list ruleset` and the NixOS config both show what is
public. Those rules sit in the input chain, which DNAT traffic skips, so the
enforcement is the table above; say so in a comment.

### Port check after start

After `up --wait`, the unit checks that each declared public port is listening
on `0.0.0.0` (`ss -Hln` with the port and protocol). Missing: the unit fails,
so Discord hears about it. This covers #22's concern that a port silently did
not bind. It does not check loopback ports; builder's call whether to add an
option for those (Grafana in 3.4 will want it, behind Tailscale Serve).

### Crash alerts

Systemd does not see a container die, so each stack also gets a watcher,
`stack-<name>-watch.service`, bound to the stack unit (`BindsTo=`, `After=`).
It runs `docker events --filter label=com.docker.compose.project=<name>
--filter event=die` and, for each event, posts the container name and exit
code through #20's notifier.

- **Daemon restarts:** the `docker events` stream ends when the daemon
  restarts. The watcher has `Restart=always` with a short delay, so it
  reconnects; deaths during the gap are not reported (Docker still restarts
  the container). The watcher has `Wants=`/`After=` `docker.service`, not
  `Requires=`, for the same reason as the stack unit.
- **Who gets pinged (Alex's choice):** a crash Docker recovers from posts
  quietly, without pinging the role. If the same container keeps crashing,
  the alert pings. Claude's call for "keeps crashing": a third death of the
  same container within the cooldown window (600 s) pings, once per window.
- **Rate limit:** at most one post per container per cooldown (the notifier's
  existing `cooldown`, 600 s), with the count of further deaths in the next
  post. A crash loop is one alert, then a count.
- A `down` (stop, removal, deploy restart) also emits `die`. The watcher must
  not alert for those. Builder's call how: the watcher stops before `down`
  (it is bound to the unit and ordered after it, so it stops first), and
  `docker compose down` exit codes are 0/143 from SIGTERM; ignore deaths while
  the stack unit is deactivating.
- The notifier's sending script is currently internal to `notify.nix`; expose
  what the watcher needs (an option or a package), without putting the
  webhook on a command line.

### The flake check over `stacks/`

A check derivation runs a small Python checker (with PyYAML) over every
compose file under `stacks/`, given the declared ports exported from the nuc's
configuration as JSON. It fails if a compose file:

1. publishes a port without a host address, in short syntax
   (`"25565:25565"`, `"25565"`, `"8000-8010:8000-8010"`) or long syntax (no
   `host_ip`);
2. publishes a port on `0.0.0.0` (or `::`, or an empty host) that its stack
   does not declare, ranges expanded;
3. sets `com.docker.network.bridge.host_binding_ipv4` in any network's
   `driver_opts`;
4. uses `network_mode: host`;
5. mounts `/var/run/docker.sock` or `/run/docker.sock`, in short or long
   volume syntax;
5b. bind-mounts a relative path, or an absolute one outside the stack's
   `dataDir` (see Data paths);
6. (new, agreed with Alex) **declares a public port that no compose file in
   the stack publishes**, so a removed game does not leave a hole open;
7. (builder's call) names a service set the override does not cover, if the
   service-name option is chosen.

Each rule gets a negative-control fixture under `tests/compose-check/`, which
the check itself runs and expects to fail with that rule's message; plus a
mutation run per rule in the PR. Variable interpolation (`${PORT}`) in a ports
entry: reject it, since the check cannot see the value.

### The VM test

`tests/compose-stack.nix` and `.py`, two machines on one VLAN (virtual LAN),
in the style of `tests/docker.nix`:

- The fixture stack lives under `tests/`, outside `stacks/`, so the check does
  not scan it. It publishes one declared port with `0.0.0.0:` and one
  undeclared port **without** an address (the case the default exists for), and
  a third, undeclared `0.0.0.0:` port that only the firewall table stops.
- The image comes from `dockerTools`, as in `tests/docker.nix`; no registry.
- Subtests:
  - `stack-fixture` is active after boot; the containers sit under
    `stack-fixture.slice`; `MemoryMax` is enforced (a container allocating
    past the limit is OOM-killed);
  - the client reaches the declared port over IPv4, and the journal has the
    log line with the client's address;
  - the client times out on the undeclared port over IPv4 and IPv6 (NixOS
    drops rather than rejects);
  - the client times out on the undeclared `0.0.0.0` port (the firewall
    layer); a log line records the drop;
  - with `allowedSources` set to an address that is not the client's, the
    declared port times out;
  - killing a container: Docker restarts it, and the notifier receives one
    post without the role mention; killing it twice more within the window
    produces one post with the mention (point the notifier at a stub webhook served in the test, as
    `tests/notify.nix` does);
  - changing the fixture's compose file and switching restarts only that
    stack (a second stack's containers keep their IDs);
  - `systemctl restart docker`: the stack unit stays active, its containers
    keep their IDs and processes (no `down`), and the watcher reconnects
    (a container killed afterwards is still alerted);
  - a port that does not bind fails the unit.
- In-test negative controls, as specialisations: remove `default-network-opts`
  (the undeclared no-address port becomes reachable, so the test's own
  assertion fails, and the control asserts that); remove the firewall table
  (the undeclared `0.0.0.0` port becomes reachable).

### The `hello` example

`stacks/hello/`: one small web server (an image with a pinned tag),
publishing `"127.0.0.1:8080:80"`-style loopback only, no public ports, no
secret. It proves the module end to end on the real nuc through comin:
`systemctl status stack-hello` active, `curl 127.0.0.1:<port>` answers on the
nuc, nothing new on `lan0`.

### Docs

- `docs/runbooks/stacks.md` (new): adding a stack, declaring a public port,
  what the check rejects and why, reading the access log
  (`journalctl -k --grep 'stack-port'`), restarting and removing a stack,
  the hairpin limitation.
- `docs/runbooks/docker.md`: point to it; drop "until then nothing runs".
- ADR 0006: dated Consequences note on the slice correction and the firewall
  table (the "even though Docker's traffic does not pass through it" wording
  is no longer true since #22's forward filter).
- `docs/PLAN.md` 3.2 as-built note; README layout and test count.

## Left to the builder

Marked "builder's call" above: the service-name source, a port-range type,
loopback port checks, how the watcher ignores `down`, the exact nftables
priority. Plus anything the pinned versions (Docker 29.9.1, Compose as bundled)
force, recorded in the PR.

## Calls made by Claude, not yet confirmed by Alex

- The firewall table as an enforcing second layer (Alex agreed declared ports
  should be LAN-only and that access attempts should be logged; enforcement in
  the firewall is how this design gets there).
- The slice plus `cgroup_parent` route for resource limits, and the ADR note.
- The generated override for `restart:` and `cgroup_parent`.
- The watcher service, its rate limit, and "third death in 600 s" as the
  ping threshold.
- `--wait` and the after-start port check.
- `hello` on loopback only.
- `Wants=` rather than `Requires=` on `docker.service`, so stacks survive a
  daemon restart (from #22's `live-restore` decision).
- Absolute bind-mount paths under `dataDir`, checked by the flake check.
