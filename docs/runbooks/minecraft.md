# Minecraft: All the Mods 9

The `minecraft` stack (ticket 4.1, #28) runs the All the Mods 9 (ATM9)
modpack on Minecraft 1.20.1 with Forge, in
[`itzg/minecraft-server`](https://docker-minecraft-server.readthedocs.io/).
Friends reach it through Tailscale sharing only (ADR (Architecture Decision
Record) 0011); their side is in [game-access.md](game-access.md). The general
stack mechanics are in [stacks.md](stacks.md), and the data directory and its
snapshots in [data-layout.md](data-layout.md).

| What | Where |
|---|---|
| The stack | [`stacks/minecraft/`](../../stacks/minecraft/): `compose.yml`, and `default.nix` declaring it |
| The unit | `stack-minecraft.service`; the container is `minecraft-server-1` |
| The world, mods and configuration | `/srv/data/minecraft`, owned by `stack-minecraft` (40001) |
| The port | TCP (Transmission Control Protocol) 25565, admitted from `tailscale0` only |
| Secrets | `secrets/minecraft.yaml`: `CF_API_KEY`, the CurseForge API key, mounted into the container as a file; `env`, the whitelist, as the stack's `.env` |
| Memory | a 12 GB heap (`MEMORY`), and 18 GB for the whole stack (`resources.memoryMax`) |

## What is pinned

- **The pack:** `CF_FILE_ID` in `compose.yml`, the CurseForge file of the
  client pack (not its server pack; the image reads the pack's manifest).
  It is All the Mods 9-1.1.1, file 7097953, the newest on 2026-10-25. The
  pack pins Forge.
- **The image:** a dated `-java17` tag. ATM9 needs Java 17.

Friends must run the same pack version, or the server refuses them with a
mod list mismatch.

## Day to day

```bash
systemctl status stack-minecraft
journalctl CONTAINER_NAME=minecraft-server-1 -f   # the server's log
sudo docker exec minecraft-server-1 rcon-cli list # who is on
sudo docker exec -it minecraft-server-1 rcon-cli  # a console; Ctrl-D leaves
```

RCON (remote console) is reachable only inside the container: nothing
publishes its port, and the image makes a new password each time it starts.

### The whitelist

The players allowed in are friends' names, so they are kept out of this
public repo: they are the `WHITELIST` line under the `env` key of
`secrets/minecraft.yaml`, which becomes the stack's `.env`. To change it, on
the workstation:

```bash
sops secrets/minecraft.yaml
```

and edit the `env` key, which holds dotenv lines, names comma-separated:

```yaml
env: |
  WHITELIST=FirstPlayer,SecondPlayer
```

Commit the file and merge. The changed secret reloads the stack, which
recreates the container, and the list replaces the server's whitelist
(`EXISTING_WHITELIST_FILE=SYNCHRONIZE`); `ENFORCE_WHITELIST` kicks anyone
removed from it. A missing or empty `WHITELIST` fails the stack's start, naming
the key, rather than running a server no one can join. To let someone
in at once, before the merge, run `rcon-cli whitelist add <name>` as well;
the next start drops them if the file does not list them.

Check each name's spelling before merging. The image looks every name up
online when the container starts, and a name it cannot find stops the
start: the log shows `Could not resolve user from Playerdb: <name>`, the
container exits, and Docker starts it again, over and over, which the crash
watcher posts to Discord. This happened in the timing run before #28's
merge, with a made-up name.

## Updating the pack

1. Find the new file on the pack's CurseForge Files tab. Its ID is the last
   part of the file's page address.
2. Change `CF_FILE_ID` in `compose.yml` and the version in this runbook and
   in [game-access.md](game-access.md).
3. Merge. The deploy recreates the container, which installs the new pack
   over the old one. The world stays; mods the new version dropped are
   removed, and their blocks with them.
4. Tell friends to update their pack to the same version.

The nightly snapshot is the way back: take one by hand first with
`just snapshot minecraft` ([data-layout.md](data-layout.md)).

## Snapshots

The nightly snapshot pauses saving while it is taken, so the world on disk
is whole: before it, `rcon-cli save-off` and `save-all flush`; after,
`save-on`. A stopped server is snapshotted without them. If the pre-command
fails, no snapshot is taken and the unit fails, which posts to Discord.

## Start and stop times

The first start downloads the pack's mods, installs Forge and makes the
world, all inside `up --wait`, which the unit allows 15 minutes; the
container's healthcheck waits up to 15 minutes before counting failures.
Measured on the nuc, both are far inside that (the record below). comin
puts no limit of its own on a deploy, so the unit's is the one that counts.

Stopping takes about a minute. The world is saved within seconds, then the
server waits on a thread that one of the pack's mods leaves running, until
it exits on its own; `stop_grace_period` allows 75 seconds before Docker
kills it, by which time everything is saved.

## Record

| Event | Result |
|---|---|
| Timing run before merge | 2026-10-25, on the nuc, a throwaway container with the stack's image, pack and settings, no published port, removed afterwards. Image pull 10 s. First start: 400 mods downloaded and 26 client-only mods skipped by the image's own list, none needing a manual download; Forge 47.4.0 installed; healthy after 146 s (the server's own `Done` 33 s). Memory with nobody on: 14.46 GiB, so the limit went from 15 to 18 GB. `save-off`, `save-all flush` (4 s) and `save-on` all exited 0. Stop 56 s, exit code 0, world saved after 8 s. Second start healthy after 96 s, pack and Forge reported already installed. An earlier attempt with a made-up whitelist name stopped at `Could not resolve user from Playerdb` |
