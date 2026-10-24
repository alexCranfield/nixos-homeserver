# Test script for tests/stack-data.nix. `machine` is the test driver's
# machine; CASES is defined by the Nix file in front of it.

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

with subtest("the evaluation rules hold"):
    assert CASES["valid"] == [], CASES["valid"]
    assert any("must be /srv/data/a" in m for m in CASES["wrongPath"]), CASES["wrongPath"]
    assert any("uid and gid" in m for m in CASES["noOwner"]), CASES["noOwner"]
    assert any("uid" in m and "40010" in m for m in CASES["sharedUid"]), CASES["sharedUid"]
    assert any("gid" in m and "40010" in m for m in CASES["sharedGid"]), CASES["sharedGid"]
    assert CASES["uid1000Accepted"] is False
