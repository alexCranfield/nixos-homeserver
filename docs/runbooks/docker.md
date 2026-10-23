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

This only matters if the setting changes. Then recreate each network: for a
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

  Retention is journald's: by default up to 10% of the root filesystem,
  capped at 4 GB, shared with every other unit. Docker's own `log-opts` do
  not apply.
- **Weekly prune.** `docker-prune.timer` runs `docker system prune --force`:
  stopped containers, unused networks, dangling images and the build cache go.
  Volumes and images a container still uses stay. Stack data lives in bind
  mounts under `/srv/data` (3.3, #24), which prune never touches. A stack
  stopped with `docker compose stop` loses its containers at the next prune,
  and `up -d` recreates them.
- **`live-restore` is off**, the default. With it off, restarting the daemon
  (a Docker update deployed by comin) stops every container, and Compose's
  restart policies start them again. Whether to turn it on is decided by
  trying both across a deploy and a reboot on the nuc; see the record below.

## Storage

`/var/lib/docker` is its own btrfs subvolume, `@docker`
(`hosts/nuc/disko.nix`), so images and container layers stay out of
snapshots of the other subvolumes. The storage driver Docker picks there is
recorded below; it decides whether layers are btrfs subvolumes of their own or
overlay directories.

```bash
sudo docker info --format '{{.Driver}} {{.DockerRootDir}}'
findmnt /var/lib/docker
```

## Record

| Check | Result |
|---|---|
| `docker` VM test | 2026-10-23, Docker 29.9.1 under TCG (Tiny Code Generator) emulation: all 11 subtests pass in 244 s. Its two controls, switching to a configuration without each setting, bind the new port to `0.0.0.0`. With `ip` deleted from the module the test fails at the bare `docker run`, and with `default-network-opts` deleted at the network created afterwards, each binding `0.0.0.0` and `[::]`. Storage driver in the VM, on ext4: `overlayfs` |
| On the nuc after deploy: `sudo docker run --rm hello-world`, `id ops`, storage driver | to be filled in |
| `live-restore` across a deploy and a reboot | to be filled in |
