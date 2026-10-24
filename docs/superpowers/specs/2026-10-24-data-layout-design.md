# Data layout and nightly snapshots design (ticket 3.3, #24)

Date: 2026-10-24. Status: draft, for Alex's approval. Revised after a builder check and Alex's answers on the configuration warning and "snapshot now".

## Intent

Every stack's persistent data lives in one predictable place, owned by a
known user, so that backups (3.5, #26) need no per-stack setup. The ticket
also gains a second half, from Alex: when a game world is griefed or a mod
update corrupts it, he rolls that one stack back to last night's state with
one command.

The first stack that needs this is Minecraft running All the Mods 9 (ATM9)
(4.1, #28). A modded world is large, changes every night, and is where a bad
update or a griefer does the most damage.

## Goals

1. **One subvolume per stack.** A stack's data directory,
   `/srv/data/<stack>`, is its own btrfs subvolume inside `@srv`, so it can
   be snapshotted and rolled back alone.
2. **Fixed ownership.** Each stack with data declares a numeric user and
   group ID, recorded once in Nix. The data directory is owned by it, and
   the stack's containers write as it.
3. **Nightly snapshots, three kept.** Every stack with data is snapshotted
   read-only every day at 09:30 UTC (Coordinated Universal Time). The three
   newest are kept.
4. **Consistent snapshots of running servers.** A stack can supply a
   command to run just before its snapshot and one to run just after. For
   Minecraft these will be "stop saving, flush the world to disk" and
   "resume saving". The snapshot is never taken halfway through a save.
5. **Rollback with one command**, `just rollback <stack> [snapshot]`, run
   from the workstation. It stops the stack, swaps its data for the chosen
   snapshot, keeps the replaced data aside, and starts the stack again.
6. **A runbook section** (`docs/runbooks/data-layout.md`) on the layout, the
   ownership convention, running the rollback, what it affects, and how to
   clean up afterwards.
7. **Snapshot now**, `just snapshot <stack>`, for a safety point before an
   update. It takes the same consistent snapshot as the nightly one, under
   its own name, kept until Alex deletes it.
8. `hello` declares a data directory, so the subvolume, ownership, nightly
   snapshot and rollback can all be checked on the real nuc before
   Minecraft exists.

## Non-goals

- **Copies off the machine.** Snapshots live on the same disk: they undo
  "we broke the world", not "the disk died". The off-machine copy to the
  NAS stays #26's job.
- **Minecraft's own hook commands.** The module gives a stack the hook;
  writing `rcon-cli save-off` and the rest belongs to #28.
- **Snapshots of anything except stack data.** No snapshots of `@root`,
  `@home`, `@nix` or `@docker`. NixOS generations already roll the system
  back, and Docker's images can be pulled again.
- **A choice of retention per stack.** It is three for every stack. (The
  builder may make it an option with a default of 3, but nothing needs a
  different value yet.)

## Anti-goals (a failure even if it works)

- A rollback that deletes the data it replaces. The replaced data is always
  kept as a read-only snapshot until Alex removes it.
- A rollback that silently brings back the update that caused the problem
  (see "Rollback and the stack's configuration").
- A snapshot taken while the server is mid-save, or one taken silently
  after its pre-snapshot command failed.
- A rollback that touches any stack other than the one named.
- Snapshots piling up unnoticed until the disk fills.
- Container files owned by root, or by whatever user ID an image happens to
  default to.

## Decisions Alex made

- Rollback is to a local snapshot, taken nightly, with three days kept.
- It's a `just` command, plus a short runbook section on running it, its
  impact, and the clean-up afterwards.
- The snapshot pauses and flushes a running server first. A second of lag
  for a player who happens to be on is acceptable.
- The snapshot runs at 09:30 UTC: about 3:30am Mountain (2:30am in winter),
  and 10:30am UK (9:30am in winter). Friends play in Mountain time and in
  GMT (Greenwich Mean Time), and this is the quietest shared hour. It also
  finishes before the Tuesday 10:00 UTC reboot window.
- Ownership as proposed: a fixed numeric ID per stack, recorded in its Nix
  declaration, and the container runs as it.
- When the stack's configuration has changed since the chosen snapshot,
  rollback warns and asks for confirmation. Alex asked whether it could
  instead put the old configuration back itself; it can't safely, see
  below.
- A "snapshot now" command, with its snapshots kept apart from the nightly
  three and kept until deleted.

## Constraints

- **The disk** (`hosts/nuc/disko.nix`):
  - one btrfs filesystem inside LUKS (Linux Unified Key Setup), with
    subvolumes `@root` on `/`, `@nix`, `@home`, `@srv` on `/srv`,
    `@docker`, `@snapshots` on `/.snapshots`, and `@swap`;
  - everything is compressed with zstd level 1, mounted `noatime`;
  - all of them on the same filesystem, so a snapshot of `/srv/data/x` can
    live under `/.snapshots`.
- **The stack module** (`modules/containers/compose-stack.nix`, #23) is
  where this belongs:
  - `dataDir` is already an option (nullable string), but today it only
    gets a `d … 0750 root root` tmpfiles rule;
  - the flake check `compose-check` requires every bind mount to sit under
    `dataDir`, except read-only `/etc/localtime` and `/etc/timezone`;
  - the module's options, the generated override and the VM (virtual
    machine) test `tests/compose-stack.nix` all follow the conventions of
    #23.
- **No stack has data on the nuc yet** (`hello` has no `dataDir`), so
  nothing needs migrating.
- **Alerts.** Failures alert through `homeserver.notify.units`
  (`modules/base/notify.nix`): a unit listed there posts to Discord when it
  fails.
- **Remote access.** The workstation reaches the nuc as `ops@nuc` over the
  tailnet. `ops` is in `wheel`, and sudo needs no password (the `deploy`
  recipe in `justfile` uses the same route).
- **Timers use UTC**, as the reboot window does
  (`modules/base/reboot-window.nix`).
- **Repo conventions** (CLAUDE.md): a branch and pull request per ticket,
  evidence with negative controls, runbooks, acronyms expanded at first
  use. Claude may not run `just deploy`; comin deploys after the merge.

## Design

### Layout

```
/srv/data/<stack>                          btrfs subvolume, owner <uid>:<gid>, 0750
/.snapshots/stacks/<stack>/<UTC time>      nightly snapshot, read-only
/.snapshots/stacks/<stack>/manual-<UTC time>
                                           from `just snapshot`, read-only
/.snapshots/stacks/<stack>/before-rollback-<UTC time>
                                           the data a rollback replaced, read-only
/.snapshots/stacks/<stack>/<name>.config/  the stack's /etc/stacks/<stack> files
                                           when that snapshot was taken
```

Only nightly snapshots (named by time alone) count towards the three kept;
`manual-*` and `before-rollback-*` are never deleted automatically. The
rollback's listing shows all three kinds, with their sizes, so anything kept
by hand stays in view. A stack removed from Nix leaves its data and
snapshots in place, as `docs/runbooks/stacks.md` already says of its data
directory; the runbook covers deleting them. Free-space alerts are #27's
(`/srv` over 85 percent).

The time in a name is UTC, formatted so that names sort by time, for
example `2026-10-25T0930Z`.

### The subvolume is created explicitly, not by tmpfiles

A oneshot unit per stack, `stack-<name>-data.service`, creates the
subvolume if the path is missing and sets its owner and mode. It runs before
the stack's unit, which requires it. If the path exists as a plain
directory, or `/srv` is not btrfs, it fails rather than carrying on with
something that cannot be snapshotted, and the failure alerts.

tmpfiles' `v` type looks like a fit, but the tmpfiles.d manual says it
falls back to a plain directory unless `/` is itself a subvolume. The nuc
meets that; a VM test's disk would not. A directory that silently isn't a
subvolume would break snapshots without saying so. (This reading of the
manual is unverified on systemd 260; the builder may check it and use `v`
if the fallback is shown not to apply. Either way the result must be
verified as a subvolume.)

### Ownership

- **New options** on `homeserver.stacks.<name>`: `uid` and `gid`.
  - Required when `dataDir` is set.
  - In the range 30000–30999, which NixOS's own user allocation doesn't
    use.
  - Unique across stacks, enforced by an assertion.
  - The range is my call.
- **Host user and group.** The module creates `stack-<name>` with that
  user and group ID, so `ls -l` shows a name and not a bare number.
- **The containers get the numbers through the environment.**
  - The stack's unit passes `STACK_UID` and `STACK_GID` into
    `docker compose`'s environment, and compose substitutes them into the
    file: `user: "${STACK_UID}:${STACK_GID}"`, or an image's own setting,
    such as ATM9's `UID`/`GID`.
  - So the numbers are written once, in Nix.
  - The compose check's interpolation rules cover ports and volumes, not
    `user` or `environment`, so this is allowed. The builder confirms that.

### Snapshot unit and timer

`stack-<name>-snapshot.service` (oneshot), started by a timer at
`*-*-* 09:30:00` UTC with `Persistent=true`, so a missed run happens at the
next boot. It is in `homeserver.notify.units`.

1. If the stack's containers are running and the stack has a pre-snapshot
   command, run it. If it fails, take no snapshot and fail the unit, which
   alerts. The post-snapshot command still runs, as below.
2. Take the snapshot: `btrfs subvolume snapshot -r` into
   `/.snapshots/stacks/<name>/`.
3. Run the post-snapshot command, if the stack has one. It runs whether or
   not step 1 or 2 failed, so a server is never left with saving switched
   off.
4. Copy the stack's configuration, its `/etc/stacks/<name>` files (compose
   file, generated override; not the `.env`, which holds secrets), beside
   the snapshot as `<name>.config/`.
5. Delete the stack's nightly snapshots beyond the newest three, with their
   configuration copies. Never delete `manual-*` or `before-rollback-*`.

`just snapshot <stack>` starts the same steps, as `stack-snapshot <stack>
manual` over SSH, naming the snapshot `manual-<time>` and skipping step 5.

The snapshot unit, the rollback and the stack unit's reload (a comin
deploy) take one lock per stack, so none of them runs while another is
changing the stack. A deploy during a rollback waits for it to finish
rather than starting containers on a half-swapped data directory.

New options: `snapshot.preCommand` and `snapshot.postCommand`, nullable
strings run on the host as root. For #28 that is something like
`docker exec minecraft-server-1 rcon-cli save-off` then `save-all flush`,
then `save-on`; the exact commands are #28's. If the stack is stopped, the
commands are skipped: its data is already at rest.

Snapshots are on for every stack with a `dataDir`. There is no switch off
until something needs one.

### Rollback

On the nuc there is a script, `stack-rollback <stack> [snapshot]`, in the
system packages. On the workstation, `just rollback <stack> [snapshot]`
runs it over SSH as `ops`, with sudo. With no snapshot named, it lists the
stack's snapshots and exits, so seeing what exists is the same command
without the second argument.

With a snapshot named:

1. Show what will happen. If the stack's current `/etc/stacks/<name>`
   files differ from the snapshot's `<name>.config/`, show the difference
   and say plainly that the update which changed them is still deployed:
   revert it in the repo, and let comin deploy the revert, before rolling
   back, or the old data starts under the new configuration. Then ask for
   confirmation, which the rollback needs either way.
2. `systemctl stop stack-<name>` (Compose `down`).
3. Snapshot the current data read-only to `before-rollback-<time>`.
4. Delete the `/srv/data/<name>` subvolume.
5. Make a writable snapshot of the chosen snapshot at `/srv/data/<name>`.
6. `systemctl start stack-<name>`.
7. Print what was kept and how to delete it once Alex is happy.

If it fails after step 3, the data is still in `before-rollback-<time>`;
the runbook says how to put it back.

### Rollback and the stack's configuration

A world broken by a modpack update is the likeliest reason to roll back,
and the update is a change in the repo: a new pack version in the compose
file. Rolling back only the data would start last night's world under the
new pack, with the same result. Alex asked whether the rollback could put
the old configuration back for him. It can't safely: the nuc's
configuration comes from `main` through comin. Run the stack from the old
files on the nuc and comin's next deploy reloads it with the new ones, and
an automatic revert to `main` would skip Alex's review. So the rollback
detects the case and says what to do, and the runbook's order for an
update gone wrong is:

1. `just rollback <stack>` with no snapshot, to choose one and see whether
   its configuration differs.
2. Revert the update's pull request, and merge the revert; comin deploys
   it.
3. `just rollback <stack> <snapshot>`: no warning now, since the
   configurations match. The crash watcher doesn't count the
stop as a crash, as #23 already guarantees for a deliberate stop.

### Effect on #26 and #28

- **#26 (backups).** It planned to snapshot `@srv` and back that up. A
  btrfs snapshot does not include nested subvolumes, so with this layout it
  would back up empty directories. #26 should back up each stack's newest
  nightly snapshot instead. Those are consistent (taken with the hooks) and
  already read-only. Its ticket text gets updated with this pull request.
- **#28 (Minecraft).** Its "pre-backup hook" becomes the snapshot
  `preCommand` and `postCommand`. The mods folder can still be excluded
  from #26's backup, but it stays in the snapshot; that only costs disk for
  the changed blocks.

### Testing

- **VM test.** It extends `tests/compose-stack.nix` or adds a new one,
  whichever the builder prefers. It gives the VM a btrfs disk on `/srv` and
  one on `/.snapshots`, the same filesystem as on the nuc, and shows:
  - `dataDir` is a subvolume with the declared owner and mode;
  - a container writes a file owned by the stack's user ID;
  - the snapshot unit runs the pre-command before the snapshot and the
    post-command after it; a stub records the order;
  - retention keeps three nightly snapshots and never deletes
    `before-rollback-*`;
  - a failing pre-command means no snapshot and a failed unit, and the
    post-command still runs;
  - a rollback restores the earlier file and keeps the replaced data;
  - a rollback onto a snapshot whose configuration differs shows the
    difference and needs confirming, and one whose configuration matches
    does not warn;
  - a manual snapshot is kept when nightly ones are pruned;
  - a plain directory at `dataDir` fails the data unit.

  Each assertion has a negative control, as usual.
- **On the nuc**, after comin deploys:
  - `hello`'s subvolume exists with its owner;
  - the first 09:30 UTC snapshot appears;
  - a rollback on `hello` works end to end, practised with a marker file.

## My calls, from the builder check

- Containers running as the stack's user is a convention, documented and
  checked in each stack's own test (#28 for Minecraft), not enforced by
  the module: images do it differently (`user:`, or itzg's `UID`/`GID`
  after starting as root), so a central rule would need exceptions for
  most of them.
- Free-space alerting is #27's. This ticket keeps every kept snapshot
  visible in the rollback's listing and documents deleting them.
- Overlaps between rollback, the snapshot and a deploy are prevented by a
  per-stack lock, not left to the runbook.
- Retention counts the newest three nightly snapshots. A catch-up run after
  downtime is still one per missed day at most, so this matches three days.

## Left to the builder

- Whether the snapshot and rollback logic is one script or several, and
  in which language. Bash matches `stack-watch.sh`.
- How the commands to pause and resume saving are passed to the unit,
  provided they run as root on the host.
- Whether `hello`'s data directory holds anything (a marker file, made by
  hand, is enough for the rollback check).
- The exact snapshot name format, provided names sort by time.
- `btrbk` or `snapper` instead of a script, if either can run a command
  just before and after one subvolume's snapshot. As far as I found,
  neither offers that per subvolume, which is why the design uses a small
  unit of its own.
