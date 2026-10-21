# Test script for tests/notify.nix. `nuc` is the test driver's machine; PORT,
# UNITS and DEPLOY_HOOK are defined by the Nix file in front of this script.
import json
import time

SECRET = "token-that-must-not-be-logged"
URL = f"http://127.0.0.1:{PORT}/api/webhooks/1/{SECRET}"


def received():
    """Every request body so far, oldest first."""
    names = nuc.succeed("ls /var/lib/webhook-receiver").split()
    return [
        json.loads(nuc.succeed(f"cat /var/lib/webhook-receiver/{n}"))
        for n in sorted(names)
    ]


def wait_received(n, timeout=60):
    deadline = time.monotonic() + timeout
    while len(got := received()) < n:
        assert time.monotonic() < deadline, f"{len(got)} messages, expected {n}"
        time.sleep(1)
    assert len(got) == n, got
    return got[-1]


nuc.wait_for_unit("multi-user.target")
nuc.wait_for_unit("webhook-receiver.service")
nuc.wait_for_open_port(PORT)
nuc.succeed(f"printf '%s\\n' {URL} | install -D -m 0400 /dev/stdin /run/notify-test/webhook")

with subtest("every watched unit loads, with the handler attached"):
    assert "comin" in UNITS and "sshd" in UNITS and "notify-probe" in UNITS, UNITS
    for unit in UNITS:
        load = nuc.succeed(f"systemctl show -P LoadState {unit}.service").strip()
        on_failure = nuc.succeed(f"systemctl show -P OnFailure {unit}.service").strip()
        print(unit, load, on_failure)
        assert load == "loaded", (unit, load)
        assert on_failure == f"notify-failure@{unit}.service.service", (unit, on_failure)

with subtest("a failing unit posts its name and the end of its log"):
    nuc.fail("systemctl start notify-probe.service")
    msg = wait_received(1)
    content = msg["content"]
    print(content)
    assert content.startswith("**nuc: notify-probe.service failed**"), content
    assert "probe end @everyone ''' fence" in content, content
    assert content.count("```") == 2, content
    assert "line 30 " in content and "line 01 " not in content, content
    assert len(content) <= 2000, len(content)
    assert msg["allowed_mentions"] == {"parse": []}, msg

with subtest("comin's hook posts a failed deployment only"):
    nuc.succeed(f"COMIN_STATUS=done COMIN_GIT_SHA=0123456789abcdef {DEPLOY_HOOK}")
    nuc.succeed(
        "COMIN_STATUS=failed COMIN_GIT_SHA=0123456789abcdef "
        "COMIN_GIT_MSG='Break a unit (#999)' "
        f"COMIN_ERROR_MSG='switch-to-configuration exited with 4' {DEPLOY_HOOK}"
    )
    # Sent in that order: had the first posted, it would be the one here.
    content = wait_received(2)["content"]
    print(content)
    assert content.startswith("**nuc: comin deployment failed**"), content
    assert "commit 0123456789ab: Break a unit (#999)" in content, content
    assert "switch-to-configuration exited with 4" in content, content

with subtest("the webhook URL is not in the journal"):
    nuc.succeed("journalctl --sync")
    nuc.fail(f"journalctl --no-pager -o cat | grep -F {SECRET}")
