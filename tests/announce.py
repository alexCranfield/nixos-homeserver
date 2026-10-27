# Test script for tests/announce.nix. `nuc` is the test driver's machine;
# PRIVATE_SECRET, PUBLIC_SECRET, ROLE, BUILD_HOOK, DEPLOY_HOOK, CALENDAR and
# REPO are defined by the Nix file in front of this script.
import datetime
import json
import re
import shlex
import shutil
import time

# "**<icon> [2026-10-27T16:26:07Z] <text>**", as homeserver-notify posts it.
STAMP = re.compile(r"^(\*\*\S+) \[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] ")


def unstamped(msg):
    m = STAMP.match(msg["content"])
    assert m, msg
    when = datetime.datetime.fromisoformat(m.group(2).replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    assert abs((now - when).total_seconds()) < 3600, (when, now)
    return {**msg, "content": m.group(1) + " " + msg["content"][m.end():]}


def received(kind):
    out = nuc.shared_dir / "webhook" / kind
    return [json.loads(f.read_text()) for f in sorted(out.glob("*.json"))]


def public(n, timeout=90):
    """Wait for the n-th public message, check there is no (n+1)-th, and
    check it pings no one and gives nothing of the host away."""
    deadline = time.monotonic() + timeout
    while len(got := received("public")) < n:
        assert time.monotonic() < deadline, f"{len(got)} public messages, expected {n}"
        time.sleep(1)
    assert len(got) == n, got
    msg = got[-1]
    print(msg["content"])
    assert msg["allowed_mentions"] == {"parse": [], "roles": []}, msg
    for private in [KERNEL, "/nix/store", ".service", "nuc:"]:
        assert private not in msg["content"], (private, msg)
    return unstamped(msg)["content"]


def game():
    """Every tellraw the stand-in server got, as parsed JSON."""
    lines = nuc.succeed("cat /var/lib/fakemc/tellraw 2>/dev/null || true").splitlines()
    return [json.loads(line) for line in lines]


def text(component):
    return "".join(part["text"] if isinstance(part, dict) else part for part in component)


def link(component):
    return [p["clickEvent"]["value"] for p in component if isinstance(p, dict) and "clickEvent" in p]


def hook(script, **env):
    assignments = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
    nuc.succeed(f"{assignments} {script}")


def build(msg, status="built", error="", root="/tmp/new-system"):
    hook(
        BUILD_HOOK,
        COMIN_PHASE="build",
        COMIN_STATUS=status,
        COMIN_ERROR_MSG=error,
        COMIN_GIT_SHA="0123456789abcdef",
        COMIN_GIT_MSG=msg,
        ANNOUNCE_GCROOT=root,
    )


def deploy(status, error=""):
    hook(
        DEPLOY_HOOK,
        COMIN_PHASE="deploy",
        COMIN_STATUS=status,
        COMIN_ERROR_MSG=error,
        COMIN_GIT_SHA="0123456789abcdef",
        COMIN_GIT_MSG="Add a thing (#42)\n\nBody, mentioning (#7)",
    )


APPLYING = "Applying update. Services on the nuc may restart briefly."

shutil.rmtree(nuc.shared_dir / "webhook", ignore_errors=True)

nuc.wait_for_unit("multi-user.target")
nuc.wait_for_unit("fakemc.service")
KERNEL = nuc.succeed("uname -r").strip()

with subtest("the host announces it is up, in Discord only"):
    assert public(1) == "**🟢 The nuc is back up.**"
    assert game() == []

with subtest("a build of a new system is announced with its pull request"):
    # What comin's gcroot would point at: anything but the running system.
    nuc.succeed("ln -sfn /nix/store/0000000000000000000000000000000a-new /tmp/new-system")
    build("Add a thing (#42)\n\nBody, mentioning (#7)")
    assert public(2) == f"**🔵 {APPLYING} More info: <{REPO}/pull/42>**"
    said = game()
    assert len(said) == 1, said
    assert text(said[0]) == f"[nuc] {APPLYING} More info", said
    assert link(said[0]) == [f"{REPO}/pull/42"], said

with subtest("negative control: a build of the running system announces nothing"):
    nuc.succeed("ln -sfn $(readlink /run/current-system) /tmp/same-system")
    build("Docs only (#43)", root="/tmp/same-system")
    build("Docs only (#43)", status="already built", root="/tmp/same-system")
    build("Broken (#44)", status="failed", error="build failed")
    # A missing gcroot, as before comin's first build.
    build("Nothing built yet (#45)", root="/tmp/no-such-gcroot")
    time.sleep(5)
    assert len(received("public")) == 2, received("public")
    assert len(game()) == 1, game()

with subtest("a subject without a pull request number links the commit"):
    build("Pushed directly, see (#9) for why", status="already built")
    assert public(3) == f"**🔵 {APPLYING} More info: <{REPO}/commit/0123456789abcdef>**"
    assert link(game()[-1]) == [f"{REPO}/commit/0123456789abcdef"]

with subtest("a finished deploy is announced in both places"):
    deploy("done")
    assert public(4) == f"**🟢 Update complete. More info: <{REPO}/pull/42>**"
    assert text(game()[-1]) == "[nuc] Update complete. More info", game()
    assert len(game()) == 3, game()

with subtest("a failed deploy is announced in Discord only, its error kept private"):
    private_before = len(received("private"))
    deploy("failed", error="switch-to-configuration exited with 4")
    assert public(5) == f"**🔴 Update failed; the server is unchanged. More info: <{REPO}/pull/42>**"
    assert len(game()) == 3, game()
    nuc.wait_until_succeeds(
        f"test $(ls /tmp/shared/webhook/private/*.json | wc -l) -gt {private_before}", timeout=60
    )
    private = received("private")[-1]
    assert private["content"].startswith(f"<@&{ROLE}> "), private
    assert "switch-to-configuration exited with 4" in private["content"], private

with subtest("nuc-announce posts its text as text, pinging no one"):
    tricky = 'Down Saturday "14:00" \\ @everyone `x` <@&1>'
    nuc.succeed(f"nuc-announce {shlex.quote(tricky)} https://example.org/notes")
    assert public(6) == f"**📢 {tricky} More info: <https://example.org/notes>**"
    assert text(game()[-1]) == f"[nuc] {tricky} More info", game()
    nuc.fail("nuc-announce")

with subtest("a stopped server is skipped, without error"):
    nuc.succeed("docker stop fakemc")
    nuc.succeed("nuc-announce 'Nobody in game'")
    assert public(7) == "**📢 Nobody in game**"
    assert len(game()) == 4, game()
    nuc.succeed("docker start fakemc")

with subtest("negative control: the window posts nothing when no reboot is pending"):
    assert CALENDAR == "Tue *-*-* 09:55:00", CALENDAR
    timer = nuc.succeed("systemctl show -P TimersCalendar reboot-window.timer")
    assert "09:55:00" in timer, timer
    nuc.succeed("systemctl start reboot-window.service")
    time.sleep(5)
    assert len(received("public")) == 7, received("public")
    assert len(game()) == 4, game()

with subtest("with a reboot pending, the window warns, reminds, then reboots"):
    # A booted system with other kernel parameters, as after a deploy that
    # changed them: the window's own check then finds a reboot pending.
    nuc.succeed(
        "mkdir /tmp/booted && "
        "for f in initrd kernel kernel-modules; do ln -s $(readlink /run/current-system/$f) /tmp/booted/$f; done && "
        "echo something-else > /tmp/booted/kernel-params && "
        "ln -sfn /tmp/booted /run/booted-system"
    )
    started = time.monotonic()
    nuc.succeed("systemctl start --no-block reboot-window.service")
    warning = public(8)
    m = re.fullmatch(
        r"\*\*🟠 Scheduled maintenance: the nuc restarts at (\d\d:\d\d) UTC \(in 1 minute\)\.\*\*",
        warning,
    )
    assert m, warning
    nuc.wait_for_shutdown()
    took = time.monotonic() - started
    print(f"warning to shutdown: {took:.0f} s")
    # The warning's ten seconds, before the reboot.
    assert took >= 10, took
    said = game()
    assert [text(c) for c in said[4:]] == [
        "[nuc] " + warning.removeprefix("**🟠 ").removesuffix("**"),
        "[nuc] The nuc restarts in 1 minute.",
    ], said
    nuc.start()
    nuc.wait_for_unit("multi-user.target")
    assert public(9) == "**🟢 The nuc is back up.**"

with subtest("neither webhook URL is in the journal"):
    nuc.succeed("journalctl --sync")
    nuc.succeed("journalctl --no-pager -o cat > /tmp/journal.txt")
    assert int(nuc.succeed("wc -l < /tmp/journal.txt")) > 1000
    nuc.fail(f"grep -F -e {PUBLIC_SECRET} -e {PRIVATE_SECRET} /tmp/journal.txt")
