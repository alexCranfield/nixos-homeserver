# Test script for tests/stack-data.nix. `machine` is the test driver's
# machine; CASES is defined by the Nix file in front of it.

import datetime
import re

start_all()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("stack-keeper.service")

with subtest("the data directory is a subvolume owned by the stack"):
    machine.succeed("btrfs subvolume show /srv/data/keeper")
    assert machine.succeed("stat -c '%u:%g %a' /srv/data/keeper").strip() == "40010:40010 750"
    assert machine.succeed("stat -c '%U:%G' /srv/data/keeper").strip() == "stack-keeper:stack-keeper"
    machine.succeed("test -d /.snapshots/stacks/keeper")

with subtest("the container writes as the stack's user"):
    machine.wait_until_succeeds("test -e /srv/data/keeper/hello")
    assert machine.succeed("stat -c '%u' /srv/data/keeper/hello").strip() == "40010"

with subtest("a plain directory at dataDir fails the data unit"):
    # The data unit stays active after its run, so it is stopped (with the
    # stack, which requires it) before it can be started again.
    machine.succeed("systemctl stop stack-keeper-data.service")
    machine.succeed("btrfs subvolume delete /srv/data/keeper")
    machine.succeed("mkdir /srv/data/keeper")
    machine.fail("systemctl start stack-keeper-data.service")
    journal = machine.succeed("journalctl -u stack-keeper-data.service --no-pager")
    assert "/srv/data/keeper exists but is not a btrfs subvolume" in journal, journal
    # The stack does not start on top of it.
    machine.fail("systemctl start stack-keeper.service")
    # Restore the subvolume for what follows.
    machine.succeed("rmdir /srv/data/keeper")
    machine.succeed("systemctl start stack-keeper.service")
    machine.succeed("btrfs subvolume show /srv/data/keeper")

def stamp(unit):
    """When `unit` last became active; changes if it was restarted."""
    return machine.succeed(f"systemctl show -p ActiveEnterTimestampMonotonic {unit}").strip()


with subtest("reloading the data unit keeps the stack running"):
    before = stamp("stack-keeper.service")
    machine.succeed("systemctl reload stack-keeper-data.service")
    assert stamp("stack-keeper.service") == before
    machine.succeed("btrfs subvolume show /srv/data/keeper")

with subtest("reloading the data unit over a plain directory fails"):
    machine.succeed("systemctl stop stack-keeper.service")
    machine.succeed("btrfs subvolume delete /srv/data/keeper")
    machine.succeed("mkdir /srv/data/keeper")
    machine.fail("systemctl reload stack-keeper-data.service")
    journal = machine.succeed("journalctl -u stack-keeper-data.service --no-pager")
    assert "/srv/data/keeper exists but is not a btrfs subvolume" in journal, journal
    machine.succeed("rmdir /srv/data/keeper")
    machine.succeed("systemctl reload stack-keeper-data.service")
    machine.succeed("btrfs subvolume show /srv/data/keeper")
    machine.succeed("systemctl start stack-keeper.service")

SNAPS = "/.snapshots/stacks/keeper"


def names():
    return machine.succeed(f"ls -A {SNAPS}").split()


def nightly():
    return sorted(n for n in names() if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z", n))


def hooks():
    """The lines of /tmp/hooks as (name, time); empty if it does not exist."""
    out = machine.succeed("cat /tmp/hooks 2>/dev/null || true")
    return [(w[0], float(w[1])) for w in (line.split() for line in out.splitlines())]


def created(snap):
    shown = machine.succeed(f"btrfs subvolume show {SNAPS}/{snap}")
    found = re.search(r"Creation time:\s*(.+)", shown)
    assert found is not None, shown
    return datetime.datetime.strptime(found.group(1).strip(), "%Y-%m-%d %H:%M:%S %z").timestamp()


with subtest("a nightly snapshot runs pre, snapshot, post in order"):
    machine.succeed("rm -f /tmp/hooks")
    before = set(names())
    machine.succeed("systemctl start stack-keeper-snapshot.service")
    new = set(names()) - before
    assert len(new) == 2, new  # the snapshot and its .config
    snap = nightly()[-1]
    assert snap + ".config" in new, new
    h = hooks()
    assert [n for n, _ in h] == ["pre", "post"], h
    made = created(snap)
    assert int(h[0][1]) < made and made + 1 <= h[1][1], (h, made)
    assert machine.succeed(f"btrfs property get {SNAPS}/{snap} ro").strip() == "ro=true"
    assert machine.succeed(f"ls -A {SNAPS}/{snap}.config").split() == ["compose.yml", "override.yml"]

with subtest("a stopped stack is snapshotted without hooks"):
    machine.succeed("systemctl stop stack-keeper.service")
    machine.succeed("rm -f /tmp/hooks")
    count = len(nightly())
    machine.sleep(1)
    machine.succeed("systemctl start stack-keeper-snapshot.service")
    assert len(nightly()) == count + 1
    assert hooks() == [], hooks()
    machine.succeed("systemctl start stack-keeper.service")

with subtest("a failing pre-command takes no snapshot, fails the unit, still runs post"):
    machine.succeed("/run/booted-system/specialisation/failingPre/bin/switch-to-configuration test")
    machine.succeed("rm -f /tmp/hooks")
    before = names()
    machine.sleep(1)
    machine.fail("systemctl start stack-keeper-snapshot.service")
    assert names() == before
    assert machine.succeed("systemctl is-failed stack-keeper-snapshot.service || true").strip() == "failed"
    assert [n for n, _ in hooks()] == ["post"], hooks()
    machine.succeed("/run/booted-system/bin/switch-to-configuration test")
    machine.wait_for_unit("stack-keeper.service")

with subtest("retention keeps the newest three nightly, never manual or before-rollback"):
    made = []
    for _ in range(5):
        before = set(nightly())
        machine.sleep(1)
        machine.succeed("systemctl start stack-keeper-snapshot.service")
        made += sorted(set(nightly()) - before)
    machine.sleep(1)
    machine.succeed("stack-snapshot keeper manual")
    machine.succeed(f"btrfs subvolume snapshot -r /srv/data/keeper {SNAPS}/before-rollback-2020-01-01T000000Z")
    kept = names()
    assert len([n for n in kept if n.startswith("manual-") and not n.endswith(".config")]) == 1, kept
    assert "before-rollback-2020-01-01T000000Z" in kept, kept
    assert nightly() == made[-3:], (nightly(), made)
    for n in kept:
        if n.endswith(".config"):
            assert n[: -len(".config")] in kept, ("orphaned config", n, kept)
    for n in nightly():
        assert n + ".config" in kept, (n, kept)
    # A nightly run after the manual one prunes the same way and leaves it.
    machine.sleep(1)
    machine.succeed("systemctl start stack-keeper-snapshot.service")
    assert len(nightly()) == 3
    assert any(n.startswith("manual-") for n in names())
    assert "before-rollback-2020-01-01T000000Z" in names()
    final = names()
    for n in final:
        if n.endswith(".config"):
            assert n[: -len(".config")] in final, ("orphaned config", n, final)
    for n in nightly():
        assert n + ".config" in final, (n, final)

with subtest("a failing post-command fails the unit but leaves a whole snapshot and prunes"):
    machine.succeed("/run/booted-system/specialisation/failingPost/bin/switch-to-configuration test")
    before = nightly()
    assert len(before) == 3, before
    machine.sleep(1)
    machine.fail("systemctl start stack-keeper-snapshot.service")
    after = nightly()
    assert len(after) == 3 and after[:2] == before[1:], (before, after)
    assert after[-1] not in before
    assert machine.succeed(f"ls -A {SNAPS}/{after[-1]}.config").split() == ["compose.yml", "override.yml"]
    kept = names()
    assert before[0] not in kept and before[0] + ".config" not in kept, kept
    machine.succeed("/run/booted-system/bin/switch-to-configuration test")
    machine.wait_for_unit("stack-keeper.service")

with subtest("a reload waits for the lock, then succeeds"):
    machine.succeed("rm -f /tmp/reload.rc")
    machine.succeed("systemd-run --unit=lockholder --setenv=PATH=\"$PATH\" flock /run/lock/stack-keeper.lock sleep 30")
    machine.wait_until_succeeds("! flock -n /run/lock/stack-keeper.lock true")
    machine.execute("( systemctl reload stack-keeper.service; echo $? > /tmp/reload.rc ) > /dev/null 2>&1 &")
    machine.sleep(5)
    machine.fail("test -e /tmp/reload.rc")
    # Were the holder gone, the reload not finishing would prove nothing.
    machine.succeed("systemctl is-active lockholder.service")
    machine.wait_until_succeeds("test -e /tmp/reload.rc", timeout=120)
    assert machine.succeed("cat /tmp/reload.rc").strip() == "0"
    machine.succeed("systemctl is-active stack-keeper.service")

STILL_DEPLOYED = "The update that changed this is still deployed"
MARKER = "/srv/data/keeper/marker"


def manual_snapshot():
    """Takes a manual snapshot and returns its name."""
    before = set(names())
    machine.sleep(1)
    machine.succeed("stack-snapshot keeper manual")
    (snap,) = [n for n in set(names()) - before if not n.endswith(".config")]
    return snap


def marker():
    return machine.succeed(f"cat {MARKER}").strip()


def before_rollbacks():
    return sorted(n for n in names() if n.startswith("before-rollback-") and not n.endswith(".config"))


with subtest("rollback restores the earlier file and keeps the replaced data"):
    machine.succeed("systemctl is-active stack-keeper.service")
    machine.succeed(f"echo one > {MARKER}")
    snap = manual_snapshot()
    machine.succeed(f"echo two > {MARKER}")
    kept_before = set(before_rollbacks())
    machine.sleep(1)
    out = machine.succeed(f"stack-rollback keeper {snap} --yes")
    assert STILL_DEPLOYED not in out, out
    assert marker() == "one"
    (kept,) = set(before_rollbacks()) - kept_before
    assert machine.succeed(f"cat {SNAPS}/{kept}/marker").strip() == "two"
    assert machine.succeed(f"ls -A {SNAPS}/{kept}.config").split() == ["compose.yml", "override.yml"]
    assert f"btrfs subvolume delete {SNAPS}/{kept}" in out, out
    machine.wait_until_succeeds("systemctl is-active stack-keeper.service")
    machine.succeed("btrfs subvolume show /srv/data/keeper")
    assert machine.succeed("stat -c '%u:%g %a' /srv/data/keeper").strip() == "40010:40010 750"
    assert machine.succeed("btrfs property get /srv/data/keeper ro").strip() == "ro=false"
    machine.succeed("touch /srv/data/keeper/writable")
    # The lock is free again.
    machine.succeed("flock -n /run/lock/stack-keeper.lock true")

with subtest("rollback warns when the configuration differs, and not when it matches"):
    edited = manual_snapshot()
    machine.succeed(f"echo '# edited by hand' >> {SNAPS}/{edited}.config/compose.yml")
    before = names()
    out = machine.execute(f"stack-rollback keeper {edited} < /dev/null 2>&1")
    assert out[0] != 0, out
    assert STILL_DEPLOYED + ": revert it and let comin deploy the revert before rolling back" in out[1], out
    assert "-# edited by hand" in out[1], out
    assert "Roll back keeper to " + edited + "? [y/N]" in out[1], out
    assert names() == before
    matching = manual_snapshot()
    out = machine.execute(f"stack-rollback keeper {matching} < /dev/null 2>&1")
    assert out[0] != 0, out
    assert STILL_DEPLOYED not in out[1], out
    assert "Roll back keeper to " + matching + "? [y/N]" in out[1], out
    # The listing marks the edited one and not the matching one (the hand-made
    # 2020 snapshot has no .config at all, so it counts as differing).
    listing = machine.succeed("stack-rollback keeper")
    flagged = [l.split()[0] for l in listing.splitlines() if "config differs" in l]
    assert edited in flagged and matching not in flagged, (flagged, listing)

with subtest("a stopped stack stays stopped after rollback"):
    snap = manual_snapshot()
    machine.succeed(f"echo three > {MARKER}")
    machine.succeed("systemctl stop stack-keeper.service")
    machine.sleep(1)
    machine.succeed(f"stack-rollback keeper {snap} --yes")
    assert machine.succeed("systemctl is-active stack-keeper.service || true").strip() == "inactive"
    assert machine.succeed("docker compose -p keeper ps -q").strip() == ""
    assert marker() == "one"
    machine.succeed("systemctl start stack-keeper.service")

with subtest("a failed start after the swap prints where the old data is and how to put it back"):
    machine.succeed(f"echo before > {MARKER}")
    snap = manual_snapshot()
    machine.succeed(f"echo replaced > {MARKER}")
    # A drop-in that makes the stack's start fail.
    machine.succeed("mkdir -p /run/systemd/system/stack-keeper.service.d")
    machine.succeed("printf '[Service]\\nExecStartPre=/run/current-system/sw/bin/false\\n' > /run/systemd/system/stack-keeper.service.d/fail.conf")
    machine.succeed("systemctl daemon-reload")
    kept_before = set(before_rollbacks())
    machine.sleep(1)
    status, out = machine.execute(f"stack-rollback keeper {snap} --yes 2>&1")
    assert status != 0, out
    (kept,) = set(before_rollbacks()) - kept_before
    assert f"{SNAPS}/{kept}" in out, out
    assert "now holds the snapshot you chose, but the stack did not start" in out, out
    assert "systemctl start stack-keeper" in out, out
    assert marker() == "before"
    assert machine.succeed(f"cat {SNAPS}/{kept}/marker").strip() == "replaced"
    # The printed commands put the replaced data back.
    cmds = [l.strip() for l in out.splitlines() if l.startswith("  btrfs subvolume")]
    assert len(cmds) == 2, out
    machine.succeed("systemctl stop stack-keeper.service || true")
    for c in cmds:
        machine.succeed(c)
    assert marker() == "replaced"
    machine.succeed("rm /run/systemd/system/stack-keeper.service.d/fail.conf")
    machine.succeed("systemctl daemon-reload")
    machine.succeed("systemctl start stack-keeper.service")

with subtest("unknown stack or snapshot changes nothing"):
    machine.succeed(f"echo four > {MARKER}")
    before = names()
    machine.fail("stack-rollback nosuch")
    machine.fail("stack-rollback keeper nosuch --yes")
    (config_entry,) = [n for n in before if n.endswith(".config")][:1]
    machine.fail(f"stack-rollback keeper {config_entry} --yes")
    machine.fail("stack-rollback keeper ../keeper --yes")
    assert marker() == "four"
    assert names() == before
    machine.succeed("systemctl is-active stack-keeper.service")

with subtest("the listing shows each kind, and no .config entries"):
    listing = machine.succeed("stack-rollback keeper")
    rows = listing.splitlines()[1:]
    shown = [r.split()[0] for r in rows]
    assert shown == sorted(shown, key=lambda n: n[-18:]), shown  # newest last
    assert sorted(shown) == sorted(n for n in names() if not n.endswith(".config")), (shown, names())
    assert any(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z", n) for n in shown), shown
    assert any(n.startswith("manual-") for n in shown), shown
    assert any(n.startswith("before-rollback-") for n in shown), shown
    assert ".config" not in listing, listing
    for r in rows:
        assert len(r.split()) >= 2 and r.split()[1] != "?", r  # a size is shown

with subtest("the timer fires at 09:30 UTC"):
    assert "09:30:00" in machine.succeed("systemctl show stack-keeper-snapshot.timer -p TimersCalendar")

with subtest("a stack given a dataDir while running gets it without a restart"):
    machine.wait_for_unit("stack-late.service")
    machine.fail("test -e /srv/data/late")
    before = stamp("stack-late.service")
    machine.succeed("/run/booted-system/specialisation/lateData/bin/switch-to-configuration test")
    machine.succeed("btrfs subvolume show /srv/data/late")
    assert machine.succeed("stat -c '%u:%g %a' /srv/data/late").strip() == "40020:40020 750"
    machine.succeed("systemctl is-active stack-late-data.service")
    assert stamp("stack-late.service") == before

with subtest("the evaluation rules hold"):
    assert CASES["valid"] == [], CASES["valid"]
    assert any("must be /srv/data/a" in m for m in CASES["wrongPath"]), CASES["wrongPath"]
    assert any("uid and gid" in m for m in CASES["noOwner"]), CASES["noOwner"]
    assert any("uid" in m and "40010" in m for m in CASES["sharedUid"]), CASES["sharedUid"]
    assert any("gid" in m and "40010" in m for m in CASES["sharedGid"]), CASES["sharedGid"]
    assert CASES["uid1000Rejected"] is True
    assert CASES["gid41000Rejected"] is True
