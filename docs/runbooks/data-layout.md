# Data layout, snapshots and rollback

Ticket 3.3 (#24). Each stack that keeps data has one place for it,
`/srv/data/<stack>`, owned by a fixed user, snapshotted every night, and
rolled back with one command. The code is in
`modules/containers/stack-data.nix`; the stack module itself is in
[stacks.md](stacks.md). The design, with the reasons, is in
`docs/superpowers/specs/2026-10-24-data-layout-design.md`.

## Where things are

| Thing | Where |
|---|---|
| A stack's data | `/srv/data/<stack>`: its own btrfs subvolume inside `@srv`, owner `<uid>:<gid>`, mode 0750 |
| Nightly snapshot | `/.snapshots/stacks/<stack>/<UTC time>`, read-only, e.g. `2026-10-25T093000Z` |
| Manual snapshot | `/.snapshots/stacks/<stack>/manual-<UTC time>`, from `just snapshot` |
| Data a rollback replaced | `/.snapshots/stacks/<stack>/before-rollback-<UTC time>` |
| The stack's files at that time | `<snapshot name>.config/` beside each snapshot: `compose.yml` and `override.yml`, not `.env`, which holds secrets |
| What the scripts read | `/etc/stacks/<stack>/snapshot.json`: the directory, the IDs, how many nightly snapshots to keep, the hook commands |

The time is UTC (Coordinated Universal Time) and names sort by time.
`@snapshots` is a separate subvolume on the same disk, so a snapshot of
`/srv/data/<stack>` can live there.

`stack-<stack>-data.service` makes the subvolume before the stack starts, and
sets the owner and mode of the top directory. If `/srv/data/<stack>` already
exists as a plain directory, or `/srv` is not btrfs, the unit fails and the
stack does not start, because a directory that cannot be snapshotted would
fail silently later. The failure posts to Discord when notifications are on
([notifications.md](notifications.md)). The data unit is wanted by
`multi-user.target` even for a stack with `autoStart = false`, so every stack
with data gets its subvolume. The stack requires it, so stopping the data
unit by hand stops the stack. Removing a stack's `dataDir` from the config
does the same at the next deploy: switching stops the removed data unit, the
old `Requires=` takes the stack down, and it comes back with
`multi-user.target`, so expect one `down` and one `up`.

## Ownership

Every stack with a `dataDir` declares `uid` and `gid`, written once in Nix:

```nix
homeserver.stacks.hello = {
  dataDir = "/srv/data/hello";   # must be /srv/data/<name>
  uid = 40000;
  gid = 40000;
};
```

- The IDs (user and group IDs) are in 40000-40999. NixOS's own build users
  use 30000-31000, so nothing else lands there.
- Each `uid` and each `gid` is unique across stacks; evaluation fails
  otherwise. Pick the next free number.
- The module creates the host user and group `stack-<name>` with those IDs,
  so `ls -l` shows a name.
- The stack's unit passes the numbers to Compose as `STACK_UID` and
  `STACK_GID`. A compose file uses them where its image takes a user:

  ```yaml
  user: "${STACK_UID}:${STACK_GID}"   # or an image's own UID and GID settings
  ```

  Running as that user is a convention, not enforced: images differ in how
  they take a user, so each stack's ticket checks its own. Files a
  container writes as root would be owned by root on the host.
- Changing a stack's `uid` later changes the top directory only. Files
  already inside keep their old owner, so `chown -R` them by hand.

## The nightly snapshot

`stack-<stack>-snapshot.timer` runs at 09:30 UTC every day: about 3:30am
Mountain (2:30am in winter), 10:30am UK (9:30am in winter), and before the
Tuesday 10:00 UTC reboot window. A run missed because the nuc was off
happens at the next boot (`Persistent`). That run can start alongside the
stack's first start, which holds the lock during image pulls; if the
snapshot's 900 second wait runs out it fails and alerts, and it runs again
the next night.

Each run, in `stack-<stack>-snapshot.service`:

1. If the stack's containers are running and it has a `snapshot.preCommand`,
   run it (for Minecraft, stop saving and flush the world; the commands are
   #28's). If it fails, no snapshot is taken and the unit fails.
2. Take the read-only snapshot.
3. Run `snapshot.postCommand`, if there is one. It runs even when step 1 or 2
   failed, so a server is never left with saving off.
4. Copy `compose.yml` and `override.yml` beside the snapshot.
5. Delete the nightly snapshots beyond the newest three, with their
   `.config` copies. `manual-*` and `before-rollback-*` are never deleted
   automatically.

A stopped stack skips the hooks: its data is already at rest. If Docker
cannot say whether the stack is running, the run fails rather than
snapshot a live server without its hooks. A failed unit posts to Discord.

The snapshot, a rollback, and the stack unit's `up` (a deploy or a start)
take one lock per stack, so none runs while another changes the stack. The
stack unit waits up to 600 seconds for it, the snapshot and the rollback up
to 900 seconds.

## Snapshot now

Before an update, take a safety point:

```bash
just snapshot minecraft
```

It runs `stack-snapshot <stack> manual` on the nuc over SSH, as `ops` with
sudo: the same hooks and the same snapshot as the nightly one, named
`manual-<UTC time>`, and no pruning. It stays until you delete it.

## Rolling back

```bash
just rollback hello                     # list the snapshots
just rollback hello 2026-10-25T093000Z  # roll back to one
```

With no snapshot, it lists them all (nightly, `manual-*` and
`before-rollback-*`), newest last, with the space only each one holds, and
marks `config differs` on any whose saved files are not the deployed ones.
That includes the `before-rollback-*` snapshots, so anything kept by hand
stays in view.

With a snapshot it shows the plan and asks `[y/N]`. Add `--yes` to skip the
question (`just rollback hello <snapshot> --yes`). If the stack's
configuration differs from the snapshot's, it shows the difference first and
warns that the update which changed it is still deployed: the old data would
start under the new configuration. Then, if you confirm:

1. It stops `stack-<stack>` (Compose `down`). A deliberate stop is not
   counted as a crash.
2. It takes the lock, and keeps the current data as `before-rollback-<time>`
   (read-only, with its `.config`).
3. It deletes `/srv/data/<stack>` and makes a writable copy of the chosen
   snapshot there, with the stack's owner and mode.
4. It starts the stack again, if it was running when you began. A stack that
   was not running (stopped, or `failed` after a bad update) is not started:
   it says its state and how to start it.
5. It prints what it kept and the line that deletes it.

It aborts with nothing changed, and restarts the stack if it was running, if
anything of the stack is still running after the stop, if it cannot take the
lock in 15 minutes, if it cannot keep the current data, or if the
`before-rollback` name already exists (two rollbacks in one second). It also
refuses a name that is not in the listing.

If it fails after keeping the data, it prints the recovery steps: a
`systemctl stop stack-<stack>` line (so a deploy cannot start the unit while
you restore) and then a `docker ps -aq --filter
label=com.docker.compose.project=<stack> | xargs -r docker rm -f` line when
the data was already swapped (a failed start may have left containers running
on the new data), then the `btrfs subvolume delete`
and `btrfs subvolume snapshot` lines that put `before-rollback-<time>` back,
then `systemctl start stack-<stack>` if the stack was running. Run them on
the nuc as root.

### An update gone wrong

A world broken by a modpack update is the likeliest reason to roll back, and
the update is a change in the repo. Rolling back only the data would start
last night's world under the new pack, with the same result. The nuc's
configuration comes from `main` through comin, so the rollback cannot put the
old files back itself: comin would load the new ones at its next deploy. So,
in this order:

1. `just rollback <stack>`: pick a snapshot, and see whether it says
   `config differs`.
2. Revert the update's pull request and merge the revert; comin deploys it.
3. `just rollback <stack> <snapshot>`. The configurations now match, so there
   is no warning.

### Impact

The stack is down from the stop to the start (the time depends on how long
its containers take to stop and start), and players on it are disconnected. Nothing else is touched: the rollback works on the one stack
named. A deploy that arrives during it waits for the lock.

## Clearing up

Kept snapshots use disk only for blocks that changed since, but nothing
removes `manual-*` or `before-rollback-*` for you. Free-space alerts are #27.
Delete a snapshot, and its saved files, as root on the nuc:

```bash
sudo btrfs subvolume delete /.snapshots/stacks/<stack>/before-rollback-<time>
sudo rm -rf /.snapshots/stacks/<stack>/before-rollback-<time>.config
```

The same two lines clear a `manual-*` one. A rollback prints them with the
name filled in.

A stack removed from Nix keeps its data and its snapshots. To delete them
once you are sure:

```bash
sudo btrfs subvolume delete /srv/data/<stack>
sudo ls /.snapshots/stacks/<stack>   # delete each snapshot as above
sudo rmdir /.snapshots/stacks/<stack>
```

## What snapshots are not

They live on the same disk as the data. They undo "the world was griefed" or
"the update broke it", not a dead disk, a stolen nuc or a deleted `@srv`.
Copies off the machine are the backup job (3.5, #26), which will back up each
stack's newest nightly snapshot rather than `@srv` itself, since a snapshot
of `@srv` does not include the stacks' nested subvolumes.

## Practising on `hello`

`hello` mounts nothing, so its subvolume is empty. Use a marker file to try
every step:

```bash
ssh ops@nuc sudo touch /srv/data/hello/before
just snapshot hello
ssh ops@nuc sudo touch /srv/data/hello/after
just rollback hello                      # note the manual-* name
just rollback hello manual-<UTC time>
ssh ops@nuc sudo ls /srv/data/hello      # `before` only
```

Then delete the `before-rollback-*` and `manual-*` it left.

## Record

| Check | Result |
|---|---|
| First deploy on the nuc | |
