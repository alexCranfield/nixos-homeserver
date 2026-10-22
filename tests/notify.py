# Test script for tests/notify.nix. `nuc` is the test driver's machine; PORT,
# SECRET, ROLE, UNITS and DEPLOY_HOOK are defined by the Nix file in front of
# this script.
import json
import shutil
import time

PING = f"<@&{ROLE}> "


def received():
    """Every request body so far, oldest first, read on the host."""
    out = nuc.shared_dir / "webhook"
    return [json.loads(f.read_text()) for f in sorted(out.glob("*.json"))]


def wait_received(n, timeout=90):
    """Wait for the n-th message, check there is no (n+1)-th, return it."""
    deadline = time.monotonic() + timeout
    while len(got := received()) < n:
        assert time.monotonic() < deadline, f"{len(got)} messages, expected {n}"
        time.sleep(1)
    assert len(got) == n, got
    print(got[-1]["content"])
    return got[-1]


def message(n):
    """The n-th message, already received."""
    return received()[n - 1]


def quiet(msg):
    assert msg["allowed_mentions"] == {"parse": [], "roles": []}, msg
    assert not msg["content"].startswith("<@"), msg


def pings(msg):
    assert msg["allowed_mentions"] == {"parse": [], "roles": [ROLE]}, msg
    assert msg["content"].startswith(PING), msg


def boot():
    nuc.start()
    nuc.wait_for_unit("multi-user.target")


# The shared directory outlives a run outside the build sandbox; start empty,
# before the VM (and its receiver) starts.
shutil.rmtree(nuc.shared_dir / "webhook", ignore_errors=True)

nuc.wait_for_unit("multi-user.target")

with subtest("the first boot posts that the host is up, without a ping"):
    msg = wait_received(1)
    quiet(msg)
    kernel = nuc.succeed("uname -r").strip()
    assert msg["content"] == f"**nuc is up, kernel {kernel}**", msg

with subtest("every watched unit loads, with the handler attached"):
    for unit in ["comin", "sshd", "reboot-window", "notify-probe"]:
        assert unit in UNITS, (unit, UNITS)
    for unit in UNITS:
        load = nuc.succeed(f"systemctl show -P LoadState {unit}.service").strip()
        on_failure = nuc.succeed(f"systemctl show -P OnFailure {unit}.service").strip()
        print(unit, load, on_failure)
        assert load == "loaded", (unit, load)
        assert on_failure == f"notify-failure@{unit}.service.service", (unit, on_failure)

with subtest("a failing unit posts its name and the end of its log, pinging the role"):
    nuc.fail("systemctl start notify-probe.service")
    msg = wait_received(2)
    pings(msg)
    content = msg["content"]
    assert content.startswith(f"{PING}**nuc: notify-probe.service failed**"), content
    # Broken up by a zero-width space, and allowed_mentions lets only the
    # role ping anyway.
    assert "probe end @​everyone ''' fence" in content, content
    assert "@everyone" not in content, content
    assert content.count("```") == 2, content
    assert "line 30 " in content and "line 01 " not in content, content
    assert len(content) <= 2000, len(content)

with subtest("comin's hook posts a failed deployment only"):
    nuc.succeed(f"COMIN_STATUS=done COMIN_GIT_SHA=0123456789abcdef {DEPLOY_HOOK}")
    nuc.succeed(
        "COMIN_STATUS=failed COMIN_GIT_SHA=0123456789abcdef "
        "COMIN_GIT_MSG='Break a unit (#999)' "
        f"COMIN_ERROR_MSG='switch-to-configuration exited with 4' {DEPLOY_HOOK}"
    )
    # Both ran to completion above, so a post from the first would be here.
    msg = wait_received(3)
    pings(msg)
    content = msg["content"]
    assert content.startswith(f"{PING}**nuc: comin deployment failed**"), content
    assert "commit 0123456789ab: Break a unit (#999)" in content, content
    assert "switch-to-configuration exited with 4" in content, content

with subtest("a clean shutdown posts going down, then up, without a ping"):
    nuc.shutdown()
    boot()
    # The receiver is in the VM, so what it got while going down is read
    # once it is back.
    msg = wait_received(5)
    quiet(msg)
    assert msg["content"] == f"**nuc is up, kernel {kernel}**", msg
    down = message(4)
    quiet(down)
    assert down["content"] == "**nuc is shutting down**", down

with subtest("after a power cut, the boot message says so and pings"):
    nuc.crash()
    boot()
    msg = wait_received(6)
    pings(msg)
    assert msg["content"].startswith(
        f"{PING}**nuc is up after an unclean shutdown, kernel {kernel}**"
    ), msg

with subtest("the next clean boot is reported as clean again"):
    # Ctrl-Alt-Delete starts reboot.target; QEMU, run with -no-reboot, then
    # exits instead of restarting, so the driver starts it again.
    nuc.reboot()
    nuc.wait_for_shutdown()
    boot()
    msg = wait_received(8)
    quiet(msg)
    assert msg["content"] == f"**nuc is up, kernel {kernel}**", msg
    down = message(7)
    quiet(down)
    assert down["content"] == "**nuc is rebooting**", down

with subtest("a deploy that changes the up and down unit posts nothing"):
    nuc.succeed(
        "/run/booted-system/specialisation/changed/bin/switch-to-configuration test"
    )
    desc = nuc.succeed("systemctl show -P Description notify-online").strip()
    assert desc == "Changed by a deploy", desc
    nuc.succeed("systemctl is-active notify-online")
    time.sleep(10)
    assert len(received()) == 8, received()

with subtest("a service that keeps failing and restarting posts once per cooldown"):
    nuc.succeed("systemctl start notify-flappy.service")
    nuc.wait_until_succeeds("systemctl is-failed notify-flappy.service", timeout=60)
    restarts = int(nuc.succeed("systemctl show -P NRestarts notify-flappy").strip())
    print("restarts:", restarts)
    # Several failures, each of which starts the handler (the journal says
    # "Triggering OnFailure= dependencies" each time); one message.
    assert restarts >= 2, restarts
    msg = wait_received(9)
    pings(msg)
    assert msg["content"].startswith(f"{PING}**nuc: notify-flappy.service failed**"), msg
    assert "more failures" not in msg["content"], msg
    time.sleep(10)
    assert len(received()) == 9, received()

with subtest("after the cooldown, the next message counts what was held back"):
    time.sleep(30)
    nuc.succeed("systemctl reset-failed notify-flappy.service")
    nuc.succeed("systemctl start notify-flappy.service")
    msg = wait_received(10)
    # Every failure but the posted one, from the first run.
    held = restarts
    assert msg["content"].startswith(
        f"{PING}**nuc: notify-flappy.service failed ({held} more times since the last message, not posted)**"
    ), msg

with subtest("a post that fails is logged, without the URL"):
    # A transient unit with the handler attached, as the runbook's test
    # failure; not one in its cooldown.
    nuc.succeed("systemctl stop webhook-receiver.service")
    handler = "notify-failure@notify-check.service.service"
    nuc.succeed(
        f"systemd-run --unit=notify-check -p OnFailure={handler} sh -c 'echo test failure; exit 1'"
    )
    nuc.wait_until_succeeds(f"systemctl is-failed {handler}", timeout=120)
    handler_log = nuc.succeed(f"journalctl -u {handler} -I -o cat --no-pager")
    print(handler_log)
    assert "curl: " in handler_log, handler_log
    nuc.succeed("systemctl start webhook-receiver.service")

with subtest("the webhook URL is not in the journal"):
    nuc.succeed("journalctl --sync")
    # Saved first, so a failing journalctl cannot pass as "not found".
    nuc.succeed("journalctl --no-pager -o cat > /tmp/journal.txt")
    assert int(nuc.succeed("wc -l < /tmp/journal.txt")) > 1000
    nuc.fail(f"grep -F {SECRET} /tmp/journal.txt")
