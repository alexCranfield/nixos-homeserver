# Data layout and nightly snapshots implementation plan (ticket 3.3, #24)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** each stack with data gets its own btrfs subvolume at
`/srv/data/<stack>`, owned by a fixed user ID. The subvolume is snapshotted
every night at 09:30 UTC, with save-pause hooks and the newest three kept.
`just snapshot` takes a manual snapshot, and `just rollback` restores one,
warning when the stack's configuration has changed since.

**Architecture:** `modules/containers/compose-stack.nix` gains the
options (`uid`, `gid`, `snapshot.*`). A new
`modules/containers/stack-data.nix`, imported by it, implements them:
- users and groups;
- `stack-<name>-data.service`, which creates and checks the subvolume;
- `stack-<name>-snapshot.service` and its `.timer`;
- a per-stack settings file;
- two root commands on the nuc, `stack-snapshot` and `stack-rollback`, built
  from Bash scripts beside `stack-watch.sh`.

A per-stack lock, `/run/lock/stack-<name>.lock`, is taken by the stack
unit's start and reload, by the snapshot, and by the rollback's swap.

**Tech Stack:** NixOS 26.05, btrfs-progs, util-linux `flock`, Docker
Compose, Bash (`writeShellApplication`, so shellcheck runs), and the NixOS
test driver.

**Spec:** `docs/superpowers/specs/2026-10-24-data-layout-design.md`. Read it
first; this plan does not repeat its reasons.

## Global Constraints

- **CLAUDE.md conventions:**
  - branch `ticket/24-data-layout` (it exists and holds the spec);
  - a squash-merged pull request, with evidence and negative controls in it;
  - acronyms expanded at first use in each document;
  - commit subjects under 72 characters, with **no `Co-Authored-By` or
    session trailers**.
- **Never in the repo, PRs or issues:** NAS hostnames or paths, the tailnet
  name, Alex's email, the ULA (unique local address) prefix.
- **Nix commands** need the profile sourced, or must run through
  `nix develop -c`. The flake sees git-tracked files only, so `git add` new
  files before building.
- **No KVM on the workstation.** Run VM (virtual machine) tests as
  `nix develop -c just vm-test-tcg <name>`. Give each run its own
  `XDG_RUNTIME_DIR` under `/run/user/1000`, and delete it after the run.
- **Claude may not run `just deploy`.** The nuc gets this through comin after
  the merge.
- **Exact values from the spec:**
  - data directory `/srv/data/<stack>`, mode `0750`, owned `<uid>:<gid>`;
  - snapshots under `/.snapshots/stacks/<stack>/`;
  - nightly snapshots are named by UTC time alone, as
    `date -u +%Y-%m-%dT%H%M%SZ`; manual ones are `manual-<time>`, and the
    data a rollback replaces is kept as `before-rollback-<time>`;
  - each snapshot's configuration copy is `<snapshot>.config/`, holding
    `compose.yml` and `override.yml` only, never `.env`;
  - three nightly snapshots are kept; `manual-*` and `before-rollback-*` are
    never pruned;
  - the timer is `OnCalendar=*-*-* 09:30:00` with `Persistent=true` (the
    nuc's `time.timeZone` is UTC);
  - user and group IDs are in 40000–40999 and unique;
  - the module passes `STACK_UID` and `STACK_GID` into the stack unit's
    environment.
- **Units that alert.** `stack-<name>-data` and `stack-<name>-snapshot`
  join `homeserver.notify.units`, under the same `notify.webhookFile != null`
  condition the watcher uses.
- **Match the surrounding code:** the comment style of `compose-stack.nix`
  and `stack-watch.sh`; `nix fmt`.

## Review Focus

1. **A rollback of a stack that was stopped, or has `autoStart = false`,**
   leaves it stopped afterwards. It doesn't start something Alex had off.
   Task 3 pins it.
2. **Snapshotting a stopped stack** skips both hooks: there is no container
   to `docker exec` into. It still takes the snapshot. Task 2 pins it.
3. **The `<snapshot>.config/` directories** are never counted, pruned as
   snapshots, or offered as snapshots to roll back to. Pruning a snapshot
   deletes its config copy with it. Tasks 2 and 3 pin it.
4. **A deploy (`systemctl reload`) while the snapshot or the swap holds the
   lock** waits, then succeeds. It doesn't fail at once, and doesn't run
   `up` on a missing directory. Task 2 pins it.
5. **An unknown stack name or snapshot name** given to either command fails
   with a message and changes nothing. Task 3 pins it.

---

### Task 1: Options, ownership and the data subvolume

**Files:**
- Modify: `modules/containers/compose-stack.nix`:
  - the `stackType` options: add `uid`, `gid` and `snapshot`;
  - the unit: add `environment`, `requires`/`after` on the data unit, and
    the lock (Task 2 adds the lock);
  - drop the `systemd.tmpfiles.rules` block;
  - `imports = [ ./stack-data.nix ];`.
- Create: `modules/containers/stack-data.nix`.
- Create: `tests/stack-data.nix` and `tests/stack-data.py`.
- Modify: `flake.nix` (`checks.stack-data`).
- Modify: `modules/base/vm.nix` (see Step 5).

**Interfaces:**
- **Produces options** on `homeserver.stacks.<name>`:
  - `uid`, `gid`: `nullOr (ints.between 40000 40999)`, default `null`;
  - `snapshot.preCommand`, `snapshot.postCommand`: `nullOr lines`, default
    `null`. Shell run on the host as root; Task 2 uses them.
- **Assertions,** for every stack with `dataDir != null`:
  - `dataDir == "/srv/data/${name}"`;
  - `uid` and `gid` are both set;
  - no two stacks share a `uid`, and none share a `gid`.
- **Produces units:**
  - `stack-<name>-data.service`: oneshot, `RemainAfterExit`,
    `after = [ "local-fs.target" ]`;
  - `stack-<name>.service` gains `requires`/`after` on it when `dataDir` is
    set.
- **Produces a user and group** `stack-<name>`, with `isSystemUser`, the
  declared `uid`/`gid`, and no shell or home.
- **Produces the settings file** `/etc/stacks/<name>/snapshot.json`:
  `{ name, dataDir, uid, gid, keep: 3, pre, post }`, where `pre` and `post`
  are store paths of `writeShellScript`s or `null`. Tasks 2 and 3 read it
  with `jq`.

- [ ] **Step 1: Write the failing VM test.**
  - **The node imports `../modules/containers/compose-stack.nix`**, not
    `hosts/nuc`, so the test owns its disks. Docker is from
    `../modules/containers/docker.nix`, as in `tests/compose-stack.nix`.
  - **The disk:** one extra disk (`virtualisation.emptyDiskImages`) formatted
    as one btrfs filesystem with subvolumes `@srv` and `@snapshots`, mounted
    on `/srv` and `/.snapshots` before any `stack-*-data` unit. A oneshot
    ordered before both mounts may run `mkfs.btrfs` and
    `btrfs subvolume create`.
  - **The image:** the busybox `probe:test` image, loaded the way
    `tests/compose-stack.nix` loads it.
  - **The stack `keeper`:** `dataDir = "/srv/data/keeper"`, `uid = 40010`,
    `gid = 40010`. Its compose file mounts `/srv/data/keeper:/data` and
    runs as `user: "${STACK_UID}:${STACK_GID}"`, with a command that writes
    `/data/hello`.
  - **Subtests in `tests/stack-data.py`:**
    - `"the data directory is a subvolume owned by the stack"`:
      `btrfs subvolume show /srv/data/keeper` succeeds, and
      `stat -c '%u:%g %a' /srv/data/keeper` is `40010:40010 750`;
    - `"the container writes as the stack's user"`:
      `stat -c '%u' /srv/data/keeper/hello` is `40010`;
    - `"a plain directory at dataDir fails the data unit"`:
      - stop `stack-keeper`;
      - `btrfs subvolume delete /srv/data/keeper`, then `mkdir` it;
      - `systemctl start stack-keeper-data` fails, and the journal names the
        path;
      - then restore the subvolume for later subtests.
- [ ] **Step 2: Run it and see it fail.** Run
  `nix develop -c just vm-test-tcg stack-data`. Expected: evaluation fails,
  because the option `uid` does not exist.
- [ ] **Step 3: Implement the options, assertions, user, data unit,
  environment and settings file** as in Interfaces.
  - The data unit runs `${pkgs.btrfs-progs}/bin/btrfs`:
    - if the path is missing, `subvolume create`;
    - if it exists, `subvolume show` must succeed, or the unit exits 1 with
      `<path> exists but is not a btrfs subvolume`;
    - then `chown uid:gid`, `chmod 0750`, and `install -d -m 0700` of
      `/.snapshots/stacks/<name>`.
  - The stack unit gets `environment.STACK_UID`/`STACK_GID` via
    `toString`.
- [ ] **Step 4: Run the test and see it pass.** Then the negative control:
  temporarily drop the data unit's `subvolume show` check, rerun, and
  expect the plain-directory subtest to fail. Put the check back.
- [ ] **Step 5: Keep the other configurations building.**
  - **`just vm`:** its VM has no btrfs `/srv`. In `modules/base/vm.nix`, set
    `virtualisation.vmVariant.homeserver.stacks = lib.mkForce { };`, with a
    comment explaining why.
  - **The evaluation-time rules:** add evaluation checks in
    `tests/stack-data.nix` (`lib.evalModules`, or a node's `assertions`
    built in a let) for these:
    - a `dataDir` other than `/srv/data/<name>` fails;
    - `dataDir` without `uid` fails;
    - two stacks sharing uid 40010 fail;
    - uid 1000 fails the type check.
- [ ] **Step 6:** run `nix flake check --no-build` and `nix fmt`.
- [ ] **Step 7: Commit:** "Give each stack a btrfs subvolume and a fixed
  user (#24)".

### Task 2: Nightly snapshot, hooks, retention and the lock

**Files:**
- Create: `modules/containers/stack-snapshot.sh`.
- Modify: `modules/containers/stack-data.nix` (the `stack-snapshot` package
  in `environment.systemPackages`, the snapshot service, timer and notify
  units).
- Modify: `modules/containers/compose-stack.nix` (`ExecStart` and
  `ExecReload` run under `flock -w 900 /run/lock/stack-<name>.lock`).
- Test: `tests/stack-data.nix` and `tests/stack-data.py`.

**Interfaces:**
- **Consumes:** `/etc/stacks/<name>/snapshot.json` and the lock path, from
  Task 1.
- **Produces:**
  - **The command** `stack-snapshot <stack> [manual]`, which exits non-zero
    on failure. With no second argument it takes a nightly snapshot and
    prunes; with `manual` it takes a `manual-<time>` snapshot and prunes
    nothing.
  - **`stack-<name>-snapshot.service`** runs
    `stack-snapshot <name>`, with `stack-<name>-snapshot.timer` as in the
    Global Constraints.
  - **Shared helpers, if any,** go in the same script, and Task 3 may
    source them. Name them `snapshot_names <stack>`, which prints nightly
    snapshot names oldest first, never `.config` entries.

- [ ] **Step 1: Write the failing subtests.** The `keeper` stack gets a
  `preCommand` and `postCommand` that each append a line (`pre`, `post`) to
  `/tmp/hooks`, plus a `date +%s.%N` timestamp. The snapshot's own time
  comes from `btrfs subvolume show`.
  - `"a nightly snapshot runs pre, snapshot, post in order"`:
    - start the snapshot unit;
    - `/tmp/hooks` holds `pre` then `post`, and the snapshot's creation time
      falls between them;
    - the snapshot is read-only (`btrfs property get <snap> ro` gives
      `ro=true`);
    - its `.config/` holds `compose.yml` and `override.yml` and no `.env`.
  - `"a failing pre-command takes no snapshot, fails the unit, still runs
    post"`: switch to a specialisation where `preCommand` is `exit 1`.
  - `"a stopped stack is snapshotted without hooks"` (Review Focus 2).
  - `"retention keeps the newest three nightly, never manual or
    before-rollback"` (Review Focus 3):
    - create five nightly snapshots by running the unit five times, with
      names unique by seconds;
    - add a `manual-` snapshot and a hand-made `before-rollback-` snapshot;
    - expect three nightly, the manual one and the before-rollback one, and
      no orphaned `.config/` directories.
  - `"a reload waits for the lock, then succeeds"` (Review Focus 4):
    - hold `flock /run/lock/stack-keeper.lock sleep 20` in the background;
    - `systemctl reload stack-keeper` has not finished after 5 s, and
      finishes successfully after the sleep.
  - `"the timer fires at 09:30 UTC"`:
    `systemctl show stack-keeper-snapshot.timer -p TimersCalendar` contains
    `09:30:00`.
- [ ] **Step 2: Run them and see them fail.** Run
  `nix develop -c just vm-test-tcg stack-data`. Expected: fail, because the
  unit `stack-keeper-snapshot.service` doesn't exist.
- [ ] **Step 3: Implement `stack-snapshot.sh`** as the spec's numbered
  steps.
  - **Hooks only for a running stack:** run them only if
    `docker compose -p <name> ps --status running -q` prints anything.
  - **Post always runs:** use a `trap`, so the post-command runs whenever
    the pre-command ran, even if the snapshot step fails.
  - **The lock:** hold it with `flock -w 900` on fd 9 for the whole run.
  - **Snapshot and config copy:**
    `btrfs subvolume snapshot -r`, then `cp -L` of the two config files into
    `<snapshot>.config/`.
  - **Pruning:** delete with `btrfs subvolume delete` plus `rm -r` of the
    config copy.
  - **Logging:** each step logs one line to stdout for the journal.
- [ ] **Step 4: Run them and see them pass.** Then two negative controls,
  rerunning after each and putting the code back:
  - make the trap conditional on success: the failing-pre subtest must go
    red;
  - drop `flock` from `ExecReload`: the lock subtest must go red.
- [ ] **Step 5: Commit:** "Snapshot each stack's data nightly, with save
  hooks (#24)".

### Task 3: Rollback, with the configuration warning

**Files:**
- Create: `modules/containers/stack-rollback.sh`.
- Modify: `modules/containers/stack-data.nix` (the `stack-rollback`
  package).
- Test: `tests/stack-data.py`.

**Interfaces:**
- **Consumes:** `snapshot.json`, the lock, `stack-snapshot`'s naming and
  `snapshot_names` (Task 2).
- **Produces the command** `stack-rollback <stack> [snapshot] [--yes]`:
  - **With no snapshot:** list every snapshot (nightly, `manual-*`,
    `before-rollback-*`), newest last. For each, show the exclusive size
    from `btrfs filesystem du -s` and `config differs` when its `.config/`
    doesn't match `/etc/stacks/<stack>/{compose.yml,override.yml}`. Exit 0.
  - **With a snapshot:**
    - print the plan;
    - if the configuration differs, print `diff -u` of each changed file and
      the line `The update that changed this is still deployed: revert it
      and let comin deploy the revert before rolling back, or the old data
      starts under the new configuration.`;
    - ask `Roll back <stack> to <snapshot>? [y/N]`, or skip the question
      with `--yes`;
    - then, in order:
      1. remember whether the unit was active;
      2. `systemctl stop stack-<stack>`;
      3. take the lock;
      4. take the `before-rollback-<time>` snapshot, with its `.config/`;
      5. delete `/srv/data/<stack>`;
      6. make a writable snapshot of the chosen one at `/srv/data/<stack>`,
         and restore its owner and mode;
      7. release the lock;
      8. start the unit again only if it was active;
      9. print what was kept, with the `btrfs subvolume delete` line that
         removes it.
  - **On any error after the before-rollback snapshot:** print where the old
    data is and the two commands that put it back, then exit 1.

- [ ] **Step 1: Write the failing subtests.**
  - `"rollback restores the earlier file and keeps the replaced data"`:
    1. write `one` to `/srv/data/keeper/marker`, then take a manual
       snapshot;
    2. write `two`;
    3. run `stack-rollback keeper <manual> --yes`;
    4. expect `marker` to read `one`, `before-rollback-*/marker` to read
       `two`, the stack to be active, and the owner and mode to be as in
       Task 1.
  - `"rollback warns when the configuration differs, and not when it
    matches"`:
    - in a snapshot whose `.config/compose.yml` was edited by hand,
      `stack-rollback keeper <snap> < /dev/null` prints the "still deployed"
      line and exits non-zero at the prompt, changing nothing;
    - for a matching snapshot, the output has no such line.
  - `"a stopped stack stays stopped after rollback"` (Review Focus 1).
  - `"unknown stack or snapshot changes nothing"` (Review Focus 5):
    `stack-rollback nosuch` and `stack-rollback keeper nosuch --yes` exit
    non-zero, and the marker and the snapshot list are unchanged.
  - `"the listing shows each kind, and no .config entries"` (Review
    Focus 3).
- [ ] **Step 2: Run them and see them fail.** Expected:
  `stack-rollback: command not found`.
- [ ] **Step 3: Implement `stack-rollback.sh`** as in Interfaces. Use
  `systemctl is-active --quiet` for step 1. Never call `systemctl` while
  holding the lock (deadlock with a reload waiting on it). Check that the
  snapshot argument names an existing entry and doesn't end in `.config`.
- [ ] **Step 4: Run them and see them pass.** Then the negative control:
  skip the before-rollback snapshot, and the first subtest must go red. Put
  it back.
- [ ] **Step 5: Commit:** "Roll a stack back to a snapshot, warning on
  config drift (#24)".

### Task 4: hello, just recipes, docs and tickets

**Files:**
- Modify:
  - `stacks/hello/default.nix`: `dataDir = "/srv/data/hello"`,
    `uid = 40000`, `gid = 40000`. Nothing is mounted; hello is where Alex
    practises a rollback.
  - `justfile`, adding:
    - `snapshot stack:`, which runs
      `ssh ops@nuc sudo stack-snapshot {{ stack }} manual`;
    - `rollback stack *snapshot:`, which runs
      `ssh -t ops@nuc sudo stack-rollback {{ stack }} {{ snapshot }}`;
    - a one-line comment on each, as the other recipes have.
  - `docs/runbooks/stacks.md`: the `dataDir`/`uid` example and "Adding a
    stack" step 3; the data paragraph under "Restarting, stopping,
    removing".
  - `docs/runbooks/README.md` (the new runbook's row).
  - `docs/PLAN.md` (3.3 as built).
  - `README.md` (layout rows for the new files, the just recipes table, the
    count of VM tests).
  - `hosts/nuc/disko.nix` (the `@srv` and `@snapshots` comments).
  - `docs/q-and-a/security.md` (Alex's 2026-10-24 question).
- Create: `docs/runbooks/data-layout.md`.

- [ ] **Step 1: Run `nix flake check`** and expect the `compose-check`
  manifest to include hello's `dataDir`. Check
  `nix build .#nixosConfigurations.nuc.config.system.build.toplevel` too.
- [ ] **Step 2: Write `docs/runbooks/data-layout.md`.** It covers:
  - the layout table from the spec, and the ownership convention: the ID
    range, `STACK_UID`/`STACK_GID`, and how a stack's container uses them;
  - the nightly snapshot: when it runs, the hooks, retention, and what a
    failure posts;
  - `just snapshot`;
  - `just rollback`: listing, choosing, the configuration warning, and the
    three-step order for an update gone wrong (spec, "Rollback and the
    stack's configuration");
  - the impact: the stack is down from stop to start, and players are
    disconnected;
  - clean-up: the `btrfs subvolume delete` lines for `before-rollback-*` and
    `manual-*`, and for a stack removed from Nix;
  - what snapshots are not: not a backup (see #26).

  Add a Record table, empty except for a row to fill on the nuc.
- [ ] **Step 3: Add the Q&A entry** in the existing shape:
  - heading "Is the Minecraft whitelist needed if friends come in over
    Tailscale?";
  - date 2026-10-24;
  - the quote "Do we need the user whitelist if we're using tailscale?";
  - the answer from the conversation: Tailscale gates devices, and the
    whitelist plus `online-mode` gate Minecraft accounts; with the reasons
    and the limit.
- [ ] **Step 4: Update the GitHub issues** (scan the text for `nasberrypi`,
  `nasops` and `/tank` first):
  - **#26:** replace "Pre-backup: btrfs snapshot of `@srv`…" with "back up
    each stack's newest nightly snapshot under
    `/.snapshots/stacks/<stack>/` (#24); a snapshot of `@srv` would not
    include the nested per-stack subvolumes".
  - **#28:** "Pre-backup hook" becomes the `snapshot.preCommand`/
    `postCommand` (`rcon-cli save-off`, `save-all flush`, then `save-on`),
    plus `uid`/`gid` passed to the image as `UID`/`GID`.
- [ ] **Step 5: Run `nix develop -c just check`** locally, without the VM
  tests (they are covered by Tasks 1–3), then `nix fmt`. Commit:
  "Document the data layout and rollback; hello gets data (#24)".
- [ ] **Step 6: After the merge**, which is comin's job, verify on the nuc
  over the agent socket:
  - `btrfs subvolume show /srv/data/hello`, and its owner `40000:40000`;
  - `systemctl list-timers 'stack-*-snapshot*'`;
  - after 09:30 UTC, the first snapshot exists;
  - Alex runs `just snapshot hello` and a `just rollback hello` with a
    marker file.

  Record each in the runbook's Record table, through a follow-up PR.
