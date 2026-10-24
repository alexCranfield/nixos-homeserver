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
| Its public ports | the `stack-ports` nftables table, and `allowedTCPPorts`/`allowedUDPPorts` on `lan0` |

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
3. Declare it in `stacks/<name>/default.nix`, as `stacks/hello` does:

   ```nix
   {
     homeserver.stacks.minecraft = {
       composeFile = ./compose.yml;
       services = [ "server" ];          # the compose file's service names
       envSecret = "minecraft-env";      # optional
       publicPorts = [ { port = 25565; } ];
       dataDir = "/srv/data/minecraft";
       resources.memoryMax = "8G";
     };
   }
   ```

4. Import it from `hosts/nuc/default.nix`, run `just check`, open a pull
   request.

Every service gets `restart: unless-stopped` and the stack's slice from the
generated override, so the compose file needs neither.

## Public ports

A port reachable from outside the nuc takes three things, and the check
fails if they disagree:

- the compose file publishes it on `0.0.0.0`: `"0.0.0.0:25565:25565"`, or
  `/udp` for UDP (User Datagram Protocol);
- the stack declares it in `publicPorts`;
- the router forwards it, for anything meant for the internet.

Public ports are IPv4 only (ADR, Architecture Decision Record, 0006). A port
published with no address binds to `127.0.0.1` ([docker.md](docker.md)), and
one published on `127.0.0.1` is for the nuc alone, as admin interfaces are
behind Tailscale Serve.

The firewall enforces the declaration, not just the check. Docker redirects
a published port before the NixOS input rules see it, so the `stack-ports`
table sits on the forward path, where the redirected traffic goes, and for
each new connection Docker redirected:

- to a declared port, arriving on `lan0`, from an allowed source if the port
  lists `allowedSources`: accepted and logged;
- anything else: dropped and logged.

So a declared port is open on the LAN (local area network) port only, not on
the tailnet. `allowedSources` (IPv4 addresses or ranges) restricts a port to
those sources; it is off unless set.

After `up`, the unit checks that every declared port is listening on
`0.0.0.0`, and fails, which posts to Discord, if one is not.

One case is blocked by design: a container reaching another stack's public
port through the nuc's own LAN address arrives from a Docker bridge, not
`lan0`, and is dropped. Containers that need each other share a Compose
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
| `undeclared-public` | a port on `0.0.0.0` or `[::]` that the stack does not declare | the declaration is the list of what is public |
| `declared-unused` | a declared port no service publishes on `0.0.0.0` | a removed game must not leave a hole open |
| `interpolated-port` | `${VAR}` in a port | the check cannot see the value |
| `host-binding-opt` | `host_binding_ipv4` in a network's `driver_opts` | it would undo the loopback default |
| `host-network` | `network_mode: host` | the container's ports would skip Docker's rules |
| `docker-socket` | a mount of `/var/run/docker.sock` or `/run/docker.sock` | API (application programming interface) access to the socket is root on the host |
| `bind-outside-data` | a relative bind mount, or an absolute one outside `dataDir`; read-only `/etc/localtime` and `/etc/timezone` are allowed | data belongs where it is snapshotted and backed up (3.3, #24) |
| `services-mismatch` | service names different from `services` | the override would miss a service |
| `unlisted-file` | a compose file in a directory no stack is named after, or not the stack's `composeFile` | every file under `stacks/` is checked against something |

## Restarting, stopping, removing

```bash
sudo systemctl restart stack-<name>   # down, then up
sudo systemctl stop stack-<name>      # down; comes back at the next boot or deploy that touches it
```

A deploy restarts a stack only when its compose file, its generated
override or its secret changed. Removing a stack from the configuration stops
its unit, which runs `down`; its data directory stays.

A deploy that restarts Docker leaves stacks running: the unit wants Docker
but does not require it, and `live-restore` keeps the containers through the
daemon restart ([docker.md](docker.md)).

## Crash alerts

Docker restarts a crashed container (`restart: unless-stopped`); systemd never
sees it, since the unit's own process ended after `up`. The stack's watcher
follows Docker's events and posts to Discord ([notifications.md](notifications.md)):

- the first crash of a container in 10 minutes posts without pinging;
- the third within those 10 minutes posts once, pinging the role;
- others in the window are counted, not posted.

A stack stopped on purpose, or a deploy that restarts it, does not count. The
watcher reconnects after Docker restarts; a crash during those seconds is
restarted but not posted.

## Record

| Check | Result |
|---|---|
