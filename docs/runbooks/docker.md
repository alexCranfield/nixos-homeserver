# Docker

Ticket 3.1 (#22). Rootful Docker, as ADR (Architecture Decision Record) 0006
decides, configured in `modules/containers/docker.nix`. Compose stacks become
systemd units in ticket 3.2 (#23); until then nothing runs in Docker on the
nuc.

## Using it

Nobody is in the `docker` group, `ops` included, because membership is root
without a password. Use `sudo`:

```bash
sudo docker ps
sudo docker compose -p <project> ps
sudo docker logs <container>
```

`docker compose` is the Compose plugin bundled with NixOS's Docker package.

## Published ports bind to loopback

A port published without an address, such as `ports: ["3000:3000"]` or
`docker run -p 3000:3000`, binds to `127.0.0.1` only. Docker's published ports
skip the NixOS firewall, so this default is what keeps a forgotten port off the
LAN (local area network). Two daemon settings do it, because Docker keeps the
default in two places:

| Setting | Covers |
|---|---|
| `ip = "127.0.0.1"` | the built-in `bridge` network, used by a bare `docker run` |
| `default-network-opts.bridge."com.docker.network.bridge.host_binding_ipv4" = "127.0.0.1"` | every bridge network created afterwards, including each Compose project's `<project>_default` |

To publish a port to the LAN, name the address: `"0.0.0.0:25565:25565"`. From
3.2 (#23), the port must also be declared in the stack's Nix module, and a
flake check fails on a public port that is not.

Traffic to a published port reaches the container through the firewall's
forward chain, which lets it in because Docker redirected it; containers'
own outgoing connections are allowed out of their bridges, and nothing else
is forwarded ([network.md](network.md#forwarded-traffic)).

Check what is listening, and on which address:

```bash
sudo ss -tlnp
```

### A network keeps the address it was created with

The network option is copied into a network when it is created. Compose
reuses an existing network that has not changed, so after either setting
changes, a network created before it keeps the old address. The `docker` VM
(virtual machine) test shows this: with the network default removed, a
container on an older network still publishes on loopback.

The built-in `bridge` network is rebuilt from the settings each time the
daemon starts, but with `live-restore` only when no container is running, on
any network: Docker logs "there are running containers, updated network
configuration will not take affect" and keeps the old one. So a change to
`ip` takes effect after a reboot, or after stopping every container and
restarting the daemon (`sudo systemctl restart docker`).

This only matters if a setting changes. Then recreate each other network: for a
Compose project, `sudo docker compose -p <project> down` then `up -d`; for a
network made by hand, `sudo docker network rm <name>` and create it again.
Removing a network does not touch data in bind mounts.

## Other daemon settings

- **`no-new-privileges`, daemon-wide.** A process in a container cannot gain
  privileges through a setuid binary or file capabilities. An image whose
  entrypoint needs `sudo` or `su` from a non-root user opts out per container
  with `security_opt: ["no-new-privileges=false"]`, which then shows in
  review. Entrypoints that start as root and drop to a user with `gosu` or
  `su-exec` work unchanged.
- **Logs go to journald.** `sudo docker logs <container>` still works. In the
  journal, each line carries the container's name:

  ```bash
  journalctl CONTAINER_NAME=<container> -f
  ```

  Retention is journald's: by default 10% of the btrfs filesystem holding
  `/var/log`, at most 4 GB, and less when free space falls under 15%, shared
  with every other unit. Docker's own `log-opts` do
  not apply.
- **Weekly prune.** `docker-prune.timer` runs `docker system prune --force`:
  stopped containers, unused networks, dangling images and dangling build
  cache go. Volumes stay, and so do tagged images, used or not, so images a
  stack no longer uses build up until removed with `sudo docker image prune
  --all`. Stack data lives in bind
  mounts under `/srv/data` (3.3, #24), which prune never touches. A stack
  stopped with `docker compose stop` loses its containers at the next prune,
  and `up -d` recreates them.
- **`live-restore` is on.** Containers keep running while the daemon
  restarts, which a deploy does whenever Docker or its settings change. Their
  published ports still stop answering new connections until the daemon is
  back: ports reached from the LAN briefly (probably while Docker rewrites its
  rules),
  and ports on `127.0.0.1` longer, since `docker-proxy`, which serves them,
  exits with the daemon. In the VM test, polling every 0.1 s during
  `systemctl restart docker`, the LAN path missed 6 attempts and loopback 29,
  under emulation; the container kept its process, and the configuration
  switch, which takes a deploy's path, left a container running. Docker
  supports this across patch releases; after a deploy that moves Docker by a
  minor or major version, check `sudo docker ps`. After a deploy that changes
  `ip`, the built-in network keeps its old address while any container runs
  (above). Without it, measured on the nuc on 2026-10-23,
  every container stops at a daemon restart, and only those with `restart:`
  `unless-stopped` or `always` start again, after downtime. A reboot stops
  containers either way; what comes back then is up to 3.2's (#23) stack
  units. It does not work with Docker Swarm, which is not used.

## Storage

`/var/lib/docker` is its own btrfs subvolume, `@docker`
(`hosts/nuc/disko.nix`), so images and container layers stay out of
snapshots of the other subvolumes. Docker 29 stores images through
containerd's snapshotter, and on this btrfs subvolume it picks `overlayfs`:
layers are overlay directories inside `@docker`, not btrfs subvolumes of their
own (2026-10-23, below).

```bash
sudo docker info --format '{{.Driver}} {{.DockerRootDir}}'
findmnt /var/lib/docker
```

## Record

| Check | Result |
|---|---|
| `docker` VM test | 2026-10-23, Docker 29.9.1 under TCG (Tiny Code Generator) emulation, three machines: all 19 subtests pass in 550 s. Controls in the test: without each loopback setting the new port binds `0.0.0.0`; without the forward filter the LAN neighbour reaches the far host through the nuc. Deleting a setting from the module fails the test at its subtest: `ip` at the bare `docker run`, `default-network-opts` at the network created afterwards (each binding `0.0.0.0` and `[::]`), `filterForward` at "the nuc does not route" (the neighbour got through), the egress rules at "containers reach the LAN". Docker left `FORWARD` at `ACCEPT` with forwarding on. Storage driver in the VM, on ext4: `overlayfs` |
| On the nuc after deploy | 2026-10-23, comin deployed #127 (`b643b97`) at 16:39:10 UTC as `comin-10`. `sudo docker run --rm hello-world`: `Hello from Docker!`. `id ops`: groups `users`, `wheel`; `getent group docker`: `docker:x:131:`, no members. `docker info`: `29.9.1 overlayfs /var/lib/docker journald`, driver type `io.containerd.snapshotter.v1`. `findmnt`: `/dev/mapper/cryptroot[/@docker] btrfs … compress=zstd:1`. So on btrfs too Docker 29 uses containerd's overlayfs snapshotter, not btrfs subvolumes per layer. `ip_forward` 1; Docker's `FORWARD` chain `policy accept`, NixOS's forward chain `policy drop` with the four allow rules. Nothing published. First prune: Mon 2026-10-26 00:00 UTC |
| `live-restore` | 2026-10-23. Off, on the nuc: `systemctl restart docker` killed a `restart: no` container (exit 137) and restarted an `unless-stopped` one. Turned on (#22), in the VM test, `systemctl restart docker` with a LAN client and the nuc itself polling every 0.1 s: the container kept its process (`pid 2436 -> true 2436`), LAN `200x33 000x6 200x111`, loopback `200x15 000x29 200x106`; with it off the container stopped (`pid 6704 -> false 0`; LAN `200x58 000x92`, loopback `200x55 000x95`). A configuration switch, a deploy's path, left `onmade` running. With containers running, a restarted daemon kept the built-in network's old address; with every container stopped, the next start applied `ip`. No reboot: the setting governs daemon restarts only. The nuc was rebooted by hand at 17:29 UTC (on #127's configuration) and came back with the forward filter, Docker and no failed units |
