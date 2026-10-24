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
    return sorted(n for n in names() if re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", n))


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
    assert int(h[0][1]) < made <= h[1][1], (h, made)
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
    machine.succeed(f"btrfs subvolume snapshot -r /srv/data/keeper {SNAPS}/before-rollback-20200101T000000Z")
    kept = names()
    assert len([n for n in kept if n.startswith("manual-") and not n.endswith(".config")]) == 1, kept
    assert "before-rollback-20200101T000000Z" in kept, kept
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
    assert "before-rollback-20200101T000000Z" in names()

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
