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
| Secrets | `secrets/minecraft.yaml`: `CF_API_KEY`, the CurseForge API (application programming interface) key, mounted into the container as a file; `env`, the whitelist, read by `minecraft-whitelist.service` |
| Memory | a 12 GiB Java heap (`MEMORY=12G`), and 18 GiB for the whole stack (`resources.memoryMax`) |

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

Status messages show in the chat as `[nuc] ...`: an update starting and
finishing, the reboot window's warning, and `nuc-announce` (#161,
[notifications.md](notifications.md#the-public-channel)). They go through
`rcon-cli tellraw @a`; a server still starting misses them.

`allow-flight` is on (`ALLOW_FLIGHT` in `compose.yml`, #156). Without it,
vanilla's movement check kicked a player while they fell, probably because
lag or one of the pack's mods made the fall look like flying. Every player
is whitelisted, so the check is not needed against cheating. The image
writes the setting into `server.properties` at each start; to check it:
`sudo docker exec minecraft-server-1 grep allow-flight /data/server.properties`.

### Player count

The Game servers dashboard in Grafana ([observability.md](observability.md#minecraft-player-count))
graphs how many players are on (hover for who, up to the 12 names the server
puts in its status ping, if the pack does not hide them), whether the server
answers, and how long its status ping takes. A host timer, `minecraft-status`,
pings the published port and exports the count and those names. It lives outside this stack on
purpose: changing `stacks/minecraft/` makes a deploy recreate the container
and drop everyone, and this needed no change there. By hand, `sudo docker
exec minecraft-server-1 rcon-cli list` also names who is on; keep that to the
terminal.

### The whitelist

The players allowed in are friends' names, so they are kept out of this
public repo: they are the `WHITELIST` line under the `env` key of
`secrets/minecraft.yaml`. To change it, on the workstation:

```bash
sops secrets/minecraft.yaml
```

and edit the `env` key, names comma-separated (the key holds dotenv lines,
from when it was the stack's `.env`):

```yaml
env: |
  WHITELIST=FirstPlayer,SecondPlayer
```

Commit the file and merge. Nobody is disconnected (#153). The changed
secret restarts `minecraft-whitelist.service`, which compares the list with
the running server's and applies the difference through RCON: `whitelist
add` for a new name, who can join at once, and `whitelist remove` for a
dropped one, whom the server kicks at once, since it enforces its whitelist
(`ENFORCE_WHITELIST`). Names match whatever their case. The same unit runs
after every start or restart of the stack, so a server restored from an
older snapshot, which stops and starts the stack, ends up with the current
list too. The server keeps the list in `/data/whitelist.json` between
starts. A deploy that only reloads the stack, even one that recreates the
container, does not run the unit; the new container reads the same file.

```bash
systemctl status minecraft-whitelist   # the last sync and what it changed
sudo docker exec minecraft-server-1 rcon-cli whitelist list
```

Check each name's spelling before merging. The server looks each new name
up with Mojang when it is added, and one it cannot find (`That player does
not exist`) fails the unit, which posts to Discord with its log, names
included. So does anything that is not a valid player name (3 to 16
letters, digits and underscores). The other names in the same edit are
still applied, and the server keeps running. A failed unit is tried again
on the next deploy, and posts again, until the name is fixed. Fix the name
and merge again, or run `sudo systemctl start minecraft-whitelist` once
Mojang's lookup is back if that was the cause.

The unit runs only while the stack is up. It waits up to 15 minutes for
the server to be healthy, which also covers a deploy that recreates the
container at the same moment, and fails, with the same alert, if it is
not. `sudo systemctl start minecraft-whitelist` then applies the list.

A missing `WHITELIST` line, or one that names no one, also fails the unit,
and the server's whitelist is left as it was rather than emptied.

To let someone in before a merge, `rcon-cli whitelist add <name>` works as
well, but the next sync removes anyone the file does not list.

### Join protection

The pack's clients take a long time to load, and the server puts a player
in the world before they can see or move. Mobs used to kill them while
they waited (#154). Vanilla's own protection after a join lasts only a
few seconds, which is not enough.

A small datapack, `join-protection`, now gives each player Resistance V,
which blocks all damage from mobs and falls, for 30 seconds after they
join. It applies on a player's first join, every rejoin, and the first
join after the server restarts. It is server-side only: friends install
nothing.

Its files are inline in `compose.yml` (the `configs:` at the end). The
image copies them into `world/datapacks` at each start.

- **Change the duration:** edit the `30` in `jp-protect`'s
  `effect give @s minecraft:resistance 30 4 true`, and bump the service's
  `homeserver.join-protection` label. Compose decides whether to recreate
  the container from the service's own settings, which leave out the
  files' text, and the files are copied in only when the container is
  created. Without the bump, the deploy succeeds and nothing changes.
- **Remove it:** drop the `DATAPACKS` line, the service's `configs:` and
  the top-level `configs:`. Then, with the stack stopped, run
  `sudo rm -r /srv/data/minecraft/world/datapacks/join-protection`. The
  image never deletes what it copied, so the pack stays enabled until it
  is removed by hand. The same goes for a file renamed inside it: the old
  one stays behind. Its two scoreboard objectives stay in the world too,
  which is harmless; `scoreboard objectives remove jp.left` and `jp.on`
  clear them.
- **A `/reload` protects everyone online for 30 seconds,** since it runs
  the pack's `load` function again, which clears every player's mark. The
  clearing is there for server starts, after a crash included, when no
  logout was recorded.
- **Check it on the server:**

  ```bash
  sudo docker exec minecraft-server-1 rcon-cli scoreboard objectives list
  sudo docker exec minecraft-server-1 rcon-cli data get entity <player> ActiveEffects
  ```

  The first should list `[jp.left]` and `[jp.on]`, which the pack's `load`
  function creates. The second, within 30 seconds of the player joining,
  should show `Id: 11, Amplifier: 4b`. `datapack list enabled` is no use
  here: it listed 432 datapacks, nearly all from mods, and RCON's reply
  stops at 4096 bytes, before the list reaches this one.

A change to the service in `compose.yml` (its environment, image, label
or list of configs, not the configs' text alone) recreates the container
on deploy, and that disconnects everyone online. Merge such changes when
nobody is playing.

Resistance ends when a player dies, so a player who respawns into chunks
that are still loading is not protected.

### Offline chunk loading

Chunks a team force-loads with FTB (Feed The Beast) Chunks, the pack's
claims map, stay loaded while every member of the team is offline, so
farms and machines keep running (#165). Two settings in the world's
`world/serverconfig/ftbchunks-world.snbt` do this:

- `force_load_mode: "always"`. The pack's `"default"` keeps chunks loaded
  offline only for a team with a player holding the FTB Ranks permission
  `ftbchunks.chunk_load_offline`, which no rank here grants.
- `max_idle_days_before_unforce: 7.0d`. Once nobody in a team has logged
  in for seven days, its chunks stop being force-loaded, so an abandoned
  base does not run for ever. Whether they come back when someone logs in
  again has not been checked here; if not, the player force-loads them
  again from the map.

Each team can still force-load at most 25 chunks
(`max_force_loaded_chunks`), and those chunks tick around the clock, which
costs memory and CPU (central processing unit) time with nobody on.

The file is part of the world, not this repo. The mod rewrites it at each
start, and the pack's `defaultconfigs` copy is used only when the file
does not exist (a new world, or the file deleted), so it cannot be
declared in `compose.yml` the way the join-protection files are. The
nightly snapshots keep it with the world.
To change it, with nobody online:

```bash
sudo systemctl stop stack-minecraft
sudoedit /srv/data/minecraft/world/serverconfig/ftbchunks-world.snbt
sudo systemctl start stack-minecraft
```

Stop the stack before editing. The mod writes the file out itself, so an
edit made while the server runs may be overwritten; with the stack stopped
it is read at the next start (as on 2026-10-28, the record below). The
stop saves the world first. `systemctl start` returns only once the server
is healthy, about a minute and a half. `sudoedit` keeps the file's owner,
`stack-minecraft`. A new world, or the file deleted, starts from the
pack's defaults again, so these two lines would need setting again.

To check it, with nobody online, test a chunk a team has force-loaded:

```bash
sudo docker exec minecraft-server-1 rcon-cli -- execute if loaded <x> 64 <z>
sudo docker exec minecraft-server-1 rcon-cli -- execute in minecraft:the_nether if loaded <x> 64 <z>
```

with block coordinates inside the chunk. `Test passed` means it is loaded.
Pick a chunk away from spawn and from other teams' loaders, which keep
chunks loaded too. The `--` stops `rcon-cli` reading a negative coordinate
as an option of its own. The teams' claims are in
`world/ftbchunks/<team>.snbt`, in chunk coordinates (multiply by 16 for
block coordinates); force-loaded ones have a `force_loaded` field.

## Updating the pack

1. Find the new file on the pack's CurseForge Files tab. Its ID is the last
   part of the file's page address.
2. Change `CF_FILE_ID` in `compose.yml` and the version in this runbook and
   in [game-access.md](game-access.md), and in any illustrated guide kept
   for friends outside this repo.
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
| Timing run before merge | 2026-10-25, on the nuc, a throwaway container with the stack's image, pack and settings, no published port, removed afterwards. Image pull 10 s. First start: 400 mods downloaded and 26 client-only mods skipped by the image's own list, none needing a manual download; Forge 47.4.0 installed; healthy after 146 s (the server's own `Done` 33 s). Memory with nobody on: 14.46 GiB, so the limit went from 15 to 18 GiB. `save-off`, `save-all flush` (4 s) and `save-on` all exited 0. Stop 56 s, exit code 0, world saved after 8 s. Second start healthy after 96 s, pack and Forge reported already installed. The real unit's first run, with the sops secrets and the stack's user, is the deploy: recorded below when it happens. An earlier attempt with a made-up whitelist name stopped at `Could not resolve user from Playerdb` |
| First deploy | 2026-10-25, comin deployed #147 (`bc84335`). The container started at 17:26:09 UTC and was healthy at 17:28:31 (142 s), within the unit's 15 minutes; no failed units. `/srv/data/minecraft` a subvolume owned `stack-minecraft` 750; the API key file `stack-minecraft` 0400 and `.env` root 0400; the container runs as `uid=40001`. `server.properties`: `white-list`, `enforce-whitelist` and `online-mode` true; the whitelist held one name. 25565 listened on `0.0.0.0` |
| Port reachability | From the workstation, 25565 on the nuc's LAN address timed out, and the nuc logged `stack-port drop IN=lan0`. Over Tailscale it also timed out, with no drop logged: the tailnet's live policy then granted the nuc `tcp:22` only (its packet filter, from `tailscale debug netmap`), so Tailscale refused it first. Adding `tcp:25565` to the policy, as [tailscale.md](tailscale.md) shows, is part of #135's checks |
| First manual snapshot | 17:30:04, `manual-2026-10-25T173004Z`, exit 0, `ro=true`. The server's log, all at 17:30:04: `Automatic saving is now disabled`, `Saved the game`, `Automatic saving is now enabled` |
| Restart | `systemctl restart stack-minecraft` returned after 102 s, active. A new container (`577d4d51b7fd` became `cd9709db767c`), the same world seed (`4723322516846976875`) before and after, and the pack and Forge reported already installed, nothing downloaded |
| Access over Tailscale | 2026-10-25, after the tailnet policy gained `tcp:25565` (#135). The nuc's packet filter then had two rules: Alex's devices to 22 and 25565, and shared users to 25565 only. Alex joined from his own device at 17:47; the nuc logged `stack-port accept 25565/tcp IN=tailscale0` |
| A friend through a share | 18:13, two friends who had accepted shares connected; both source addresses matched the shared-users rule. The one whitelisted in #148 joined. The other, not yet listed, was turned away: `You are not white-listed on this server!`. #149 added them; it deployed at 18:19:46 (91 s from recreate to healthy) |
| Offline chunk loading | 2026-10-28, with nobody online (#165). One team, three members, had 15 force-loaded chunks, 11 in the overworld and 4 in the Nether. Before: `execute if loaded` failed at a force-loaded chunk in each, as at an unclaimed chunk far away. The stack stopped in 5 s, with every dimension reporting `All chunks are saved`; the two values set; healthy again 92 s after the start, and the whitelist sync ran. The mod rewrote the file at start and kept both. After: both force-loaded chunks passed, the far chunk still failed. With nobody on, before, then five minutes after the start (so the later figures may settle lower): overworld tick time 2.08 to 10.52 ms, all dimensions 3.42 to 11.76 ms, 20 TPS (ticks per second) throughout; CPU 8 % to 35 %. Memory not comparable, as the JVM (Java virtual machine) had just restarted |
