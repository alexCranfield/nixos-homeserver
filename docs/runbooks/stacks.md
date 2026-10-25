# Compose stacks

Ticket 3.2 (#23). Each container workload is a Compose stack: a compose file
under `stacks/`, declared in Nix with `homeserver.stacks.<name>`
(`modules/containers/compose-stack.nix`), and run by
`stack-<name>.service`. comin deploys a stack like any other change. Docker
itself is in [docker.md](docker.md).

## What a stack is on the nuc

| Thing | Where |
|---|---|
| The unit | `stack-<name>.service`: `docker compose up` when it starts, `down` when it stops |
| Its files | `/etc/stacks/<name>/`: `compose.yml` as written, `override.yml` generated, `.env` linked to the sops secret |
| Its containers | named `<name>-<service>-1`, in `stack-<name>.slice`, which holds the memory and CPU (central processing unit) limits |
| Its crash watcher | `stack-<name>-watch.service`, which posts container crashes to Discord |
| Its public ports | the `stack-ports` nftables table, on the forward path |

```bash
systemctl status stack-<name>
sudo docker compose -p <name> ps
journalctl -u stack-<name>             # the unit: up, down, failures
journalctl CONTAINER_NAME=<name>-web-1 # a container's own output
```

## Adding a stack

1. Make `stacks/<name>/compose.yml`, written as upstream documents it, with
   two differences the flake check enforces (below): every published port
   names its host address, and bind mounts use absolute paths under the
   stack's data directory.
2. Secrets, if any, go in a sops file ([secrets.md](secrets.md)), never in the
   compose file. Declare the secret as `sops.secrets.<secret>` and name it in
   `envSecret`; it becomes the stack's `.env`. Compose reads `.env` for
   `${VAR}` in the file, and a service sees it as environment only with
   `env_file: .env`.
3. Declare it in `stacks/<name>/default.nix`, as `stacks/hello` does. A stack
   that keeps data sets `dataDir` (always `/srv/data/<name>`) with a `uid` and
   `gid`, and the compose file runs its containers as them with
   `${STACK_UID}` and `${STACK_GID}` ([data-layout.md](data-layout.md)):

   ```nix
   {
     homeserver.stacks.minecraft = {
       composeFile = ./compose.yml;
       services = [ "server" ];          # the compose file's service names
       envSecret = "minecraft-env";      # optional
       publicPorts = [ { port = 25565; interface = "tailscale0"; } ];  # a game port (ADR 0011)
       dataDir = "/srv/data/minecraft";  # a btrfs subvolume, made before the stack starts
       uid = 40010;                      # 40000-40999, unique; the container runs as it
       gid = 40010;
       resources.memoryMax = "8G";
     };
   }
   ```

4. Import it from `hosts/nuc/default.nix`, run `just check`, open a pull
   request.

Every service gets `restart: unless-stopped` and the stack's slice from the
generated override, so the compose file needs neither.

## Public ports

A port reachable from outside the nuc takes two things, and the check fails
if they disagree:

- the compose file publishes it on `0.0.0.0`: `"0.0.0.0:25565:25565"`, or
  `/udp` for UDP (User Datagram Protocol);
- the stack declares it in `publicPorts`.

"Public" here means reachable from another machine, not from the internet:
the router forwards nothing. Each declared port is admitted from one
interface, its `interface`, which is `lan0` unless set. Game ports set
`interface = "tailscale0"`, as ADR (Architecture Decision Record) 0011
decided: friends reach them through Tailscale sharing, and nothing reaches
them from the LAN (local area network). [tailscale.md](tailscale.md) has the
access policy that limits what friends reach. A port open on both would be
declared twice, once per interface.

Public ports are IPv4 only (ADR 0006). A port
published with no address binds to `127.0.0.1` ([docker.md](docker.md)), and
one published on `127.0.0.1` is for the nuc alone, as admin interfaces are
behind Tailscale Serve.

The firewall enforces the declaration, not just the check. Docker redirects
a published port before the NixOS input rules see it, so the `stack-ports`
table sits on the forward path, where the redirected traffic goes, and for
each new connection Docker redirected:

- to a declared port, arriving on that port's `interface`, from an allowed
  source if the port lists `allowedSources`: accepted and logged;
- anything else: dropped and logged.

So a declared port is open on its own interface only, `lan0` (the LAN port)
or `tailscale0`, and over IPv4 only: the input rules open nothing for it, so a
port Docker also publishes on `[::]` (served by `docker-proxy`, a host
process) stays closed over IPv6, and the check rejects `[::]` anyway. `allowedSources` (IPv4 addresses or ranges) restricts a port to
those sources; it is off unless set.

After `up`, the unit checks that every declared port is listening on
`0.0.0.0`. When it starts, a port that is not fails the unit, which posts to
Discord; when a deploy reloads it, the failure fails the deploy instead,
which comin posts, and the unit stays active.

One case is blocked by design: a container reaching another stack's public
port through the nuc's own address arrives from a Docker bridge, not the
port's interface, and is dropped. Containers that need each other share a Compose
network instead.

### Reading the access log

Each new connection to a public port is logged, at most 10 a minute per rule
with bursts of 5, so a scan fills neither the journal nor the disk:

```bash
journalctl -k --grep 'stack-port accept'   # e.g. stack-port accept 25565/tcp ... SRC=<address>
journalctl -k --grep 'stack-port drop'     # anything else Docker redirected
sudo nft list table inet stack-ports       # counters per rule
```

A drop is logged after Docker's redirect, so its `DPT=` is the container's
port, not the one the client asked for. Turning these into graphs and alerts
is tickets 3.4 (#25) and 3.6 (#27).

## What the check rejects

The flake check `compose-check` (`scripts/check_compose.py`) reads every
compose file under `stacks/` against its stack's declaration. Each rule has a
fixture in `tests/compose-check/` that must fail with it.

| Rule | Rejects | Why |
|---|---|---|
| `no-address` | a published port with no host address, in any syntax | the loopback default makes it safe, but the file should say what it means |
| `undeclared-public` | a port on `0.0.0.0` that the stack does not declare, or whose host port Docker picks | the declaration is the list of what is public |
| `ipv6-public` | a port on `::` or `[::]` | public ports are IPv4 only (ADR 0006) |
| `declared-unused` | a declared port no service publishes on `0.0.0.0` | a removed game must not leave a hole open |
| `interpolated-port` | `${VAR}` in a port | the check cannot see the value |
| `interpolated-volume` | `${VAR}` or `$VAR` in a mount's host side | the value, perhaps the Docker socket, would come from `.env` unchecked |
| `host-binding-opt` | `host_binding_ipv4` in a network's `driver_opts` | it would undo the loopback default |
| `host-network` | `network_mode: host` | the container's ports would skip Docker's rules |
| `docker-socket` | a mount of `/var/run/docker.sock` or `/run/docker.sock` | API (application programming interface) access to the socket is root on the host |
| `bind-outside-data` | a relative bind mount, or an absolute one outside `dataDir`; read-only `/etc/localtime` and `/etc/timezone` are allowed | data belongs where it is snapshotted and backed up (3.3, #24) |
| `services-mismatch` | service names different from `services` | the override would miss a service |
| `unlisted-file` | a compose file in a directory no stack is named after, or a stack whose `composeFile` is not `stacks/**/<name>/compose.yml` | every file is checked, against its own stack |

## Restarting, stopping, removing

```bash
sudo systemctl restart stack-<name>   # down, then up
sudo systemctl stop stack-<name>      # down; comes back at the next boot or deploy that touches it
```

A deploy that changes a stack's unit reloads it rather than restarting it:
`up` runs again, and Compose recreates only the services whose configuration
changed, so an update that only moves Docker's store path leaves the
containers running. A changed secret reloads it as well, and the services
that read the secret are recreated with the new values. A reload starts
Docker first if a deploy stopped it. Removing a stack from the configuration stops its
unit, which runs `down`; its data directory and its snapshots stay, and
[data-layout.md](data-layout.md) says how to delete them. Each stack's data
is snapshotted every night, and `just rollback <stack>` restores one; both
are in the same runbook.

A deploy that restarts Docker leaves stacks running: the unit wants Docker
but does not require it, and `live-restore` keeps the containers through the
daemon restart ([docker.md](docker.md)).

## Crash alerts

Docker restarts a crashed container (`restart: unless-stopped`); systemd never
sees it, since the unit's own process ended after `up`. The stack's watcher
follows Docker's events and posts to Discord ([notifications.md](notifications.md)):

- a crash that makes three or more in 10 minutes posts pinging the role, at
  most once per 10 minutes;
- any other crash posts without pinging, if nothing was posted about that
  container in the last 10 minutes;
- the rest are counted, not posted.

So a container that keeps crashing is reported at least every 10 minutes,
and pings you at most every 10 minutes while it crashes three times or more
in that time.

A stack stopped on purpose, or a deploy that restarts it, does not count. When
Docker restarts, the watcher waits for it and reconnects rather than exiting,
since a unit that fails during a deploy fails the deploy (#143); a crash
during those seconds is restarted but not posted.

## Record

| Check | Result |
|---|---|
| First deploy | 2026-10-24, comin deployed #133 (`768d281`), with `stack-hello` active from 17:52:10 UTC and Docker 29.9.1. `docker ps`: `hello-web-1 traefik/whoami:v1.10.3 ... 127.0.0.1:8080->80/tcp`. `docker inspect`: cgroup parent `stack-hello.slice`, restart `unless-stopped`; the slice's `memory.max` is `67108864`. `ss -ltn`: 8080 on `127.0.0.1` only (`docker-proxy`). `curl 127.0.0.1:8080` answers. `nft list table inet stack-ports`: the drop rule, with 0 packets dropped. `stack-hello-watch` active, and no failed units |
