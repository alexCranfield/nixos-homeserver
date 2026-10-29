# Test script for tests/alerting.nix. `nuc` is the test driver's machine;
# SECRET, ROLE, GATEWAY and IMAGE are defined by the Nix file in front of this
# script.
#
# The expected titles below follow the summaries in
# modules/observability/rules.nix with the test's thresholds filled in.
#
# API: application programming interface. JSON: JavaScript Object Notation.
import datetime
import json
import re
import shutil
import time
import urllib.parse

PING = f"<@&{ROLE}> "
AM = "http://127.0.0.1:9093"
TEXTFILE = "/var/lib/prometheus-node-exporter-text/tailscale.prom"

# The title's timestamp: "**<icon> [2026-10-22T22:57:34Z] <text>**".
STAMP = re.compile(r"^((?:<@&\d+> )?\*\*\S+) \[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] ")


def unstamped(msg):
    """The message with its title's timestamp checked, then removed."""
    m = STAMP.match(msg["content"])
    assert m, msg
    when = datetime.datetime.fromisoformat(m.group(2).replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    assert abs((now - when).total_seconds()) < 3 * 3600, (when, now)
    return {**msg, "content": m.group(1) + " " + msg["content"][m.end():]}


def received():
    """Every request body so far, oldest first, read on the host."""
    out = nuc.shared_dir / "webhook"
    return [unstamped(json.loads(f.read_text())) for f in sorted(out.glob("*.json"))]


def title(msg):
    return msg["content"].split("\n", 1)[0]


def firing(summary):
    return f"{PING}**🔴 nuc: {summary}**"


def resolved(summary):
    return f"**✅ nuc: resolved: {summary}**"


def matching(want, since=0):
    """Messages from the since-th on whose title is `want` (a string) or
    matches it (a compiled pattern)."""
    if isinstance(want, str):
        ok = lambda t: t == want  # noqa: E731
    else:
        ok = lambda t: want.fullmatch(t) is not None  # noqa: E731
    return [m for m in received()[since:] if ok(title(m))]


def wait_post(want, since=0, timeout=300):
    """Wait for the first message from the since-th on with that title."""
    deadline = time.monotonic() + timeout
    while not (got := matching(want, since)):
        if time.monotonic() > deadline:
            raise AssertionError(
                f"no post {want!r} in {timeout} s; got {[title(m) for m in received()[since:]]}"
            )
        time.sleep(1)
    msg = got[0]
    print(msg["content"])
    return msg


def pings(msg):
    assert msg["allowed_mentions"] == {"parse": [], "roles": [ROLE]}, msg
    assert msg["content"].startswith(PING), msg


def quiet(msg):
    assert msg["allowed_mentions"] == {"parse": [], "roles": []}, msg
    assert not msg["content"].startswith("<@"), msg


def check_fired(summary, since=0, timeout=300):
    msg = wait_post(firing(summary), since, timeout)
    pings(msg)
    return msg


def check_resolved(summary, since=0, timeout=300):
    msg = wait_post(resolved(summary), since, timeout)
    quiet(msg)
    return msg


def am_alerts():
    """Alertmanager's active alerts, silenced and inhibited ones included."""
    return json.loads(nuc.succeed(f"curl -fsS '{AM}/api/v2/alerts'"))


def am_state(name):
    """{state, inhibitedBy, silencedBy} of the alert named, or None."""
    for a in am_alerts():
        if a["labels"]["alertname"] == name:
            return a["status"]
    return None


def wait_am(name, check, timeout=300):
    deadline = time.monotonic() + timeout
    while not check(state := am_state(name)):
        assert time.monotonic() < deadline, f"{name}: {state}"
        time.sleep(3)
    print(name, state)
    return state


def prom(expr):
    q = urllib.parse.quote(expr, safe="")
    out = nuc.succeed(f"curl -fsS 'http://127.0.0.1:9090/api/v1/query?query={q}'")
    return json.loads(out)["data"]["result"]


def active_at(alertname, unit):
    """When Prometheus's alert for the unit became active, or None. A
    resolved alert that fires again is a new alert, with a new time."""
    out = json.loads(nuc.succeed("curl -fsS http://127.0.0.1:9090/api/v1/alerts"))
    for a in out["data"]["alerts"]:
        if a["labels"]["alertname"] == alertname and a["labels"].get("name") == unit:
            return a["activeAt"]
    return None


def wait_active_at(alertname, unit, timeout=120):
    deadline = time.monotonic() + timeout
    while (at := active_at(alertname, unit)) is None:
        assert time.monotonic() < deadline, f"no {alertname} for {unit}"
        time.sleep(1)
    return at


def unit_failed(unit):
    return f"Unit {unit}.service failed"


# The shared directory outlives a run outside the build sandbox; start empty,
# before the VM (and its receiver) starts.
shutil.rmtree(nuc.shared_dir / "webhook", ignore_errors=True)

nuc.wait_for_unit("multi-user.target")
nuc.wait_for_unit("alertmanager.service")
nuc.wait_for_unit("alert-relay.service")
nuc.wait_for_unit("prometheus.service")
# Under emulation, Docker's containerd can time out on its first start, and
# Docker's restart restarts cAdvisor (tests/observability.py).
nuc.wait_for_unit("docker.service")
nuc.wait_for_unit("cadvisor.service")
print(nuc.succeed("systemctl list-units --failed --no-pager"))
print(nuc.succeed("ip -br addr"))

with subtest("4. a dead gateway posts, and holds back DnsFailing and TailnetDisconnected"):
    # First: these three fire from boot, and the inhibition must already
    # hold when the two it targets fire.
    nuc.fail(f"ping -c 1 -W 2 {GATEWAY}")
    gw = "The LAN gateway does not answer ping (for 15s)"
    dns = "DNS lookups through the nuc's resolver fail (for 60s)"
    tailnet = "The nuc is not connected to the tailnet (for 60s)"
    check_fired(gw)
    # Firing, and held back: the alerts reached Alertmanager, so the missing
    # posts below are the inhibition's doing.
    for name in ("DnsFailing", "TailnetDisconnected"):
        state = wait_am(name, lambda s: s is not None and s["inhibitedBy"], timeout=600)
        assert state["state"] == "suppressed", state
    # A flush of their groups has passed (group_wait 10 s).
    time.sleep(20)
    assert matching(firing(dns)) == [], received()
    assert matching(firing(tailnet)) == [], received()

    # The gateway answers: its alert resolves, and the two it held back are
    # posted on their own, at their groups' next flush.
    n = len(received())
    nuc.succeed(f"ip addr add {GATEWAY}/32 dev lo")
    nuc.succeed(f"ping -c 1 -W 2 {GATEWAY}")
    check_resolved(gw, n)
    check_fired(tailnet, n)
    check_fired(dns, n)

    # Tailscale's state as a logged-in node reports it, held still: the
    # timer would write 0 again.
    n = len(received())
    nuc.succeed("systemctl stop tailscale-state.timer tailscale-state.service")
    nuc.succeed(
        f"printf 'homeserver_tailscale_running 1\\nhomeserver_tailscale_health_messages 0\\n' > {TEXTFILE}.tmp"
        f" && mv {TEXTFILE}.tmp {TEXTFILE}"
    )
    check_resolved(tailnet, n)
    # DnsFailing stays firing: this VM has no DNS upstream. It never posts
    # again (repeat_interval 12 h), so the counts below are not disturbed.

with subtest("1. TargetDown: a stopped node-exporter posts once, then resolves"):
    target = "Scrape target node is down (for 30s)"
    n = len(received())
    start = time.monotonic()
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    check_fired(target, n)
    print(f"TargetDown: {time.monotonic() - start:.0f} s from stop to post")
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    check_resolved(target, n)
    assert len(matching(firing(target), n)) == 1, received()[n:]

with subtest("2. UnitFailed: an unwatched unit posts; a watched one posts once, the notifier's"):
    n = len(received())
    start = time.monotonic()
    nuc.succeed("systemd-run --unit fail-me false")
    check_fired(unit_failed("fail-me"), n)
    print(f"UnitFailed: {time.monotonic() - start:.0f} s from failure to post")
    nuc.succeed("systemctl reset-failed fail-me.service")
    check_resolved(unit_failed("fail-me"), n)
    assert len(received()) == n + 2, received()[n:]

    # Negative control: cAdvisor is watched, so its failure is the
    # notifier's to post; UnitFailed skips it, and its TargetDown is held
    # back while it is failed.
    n = len(received())
    nuc.succeed("systemctl kill -s KILL cadvisor.service")
    nuc.wait_until_succeeds("systemctl is-failed cadvisor.service", timeout=60)
    time.sleep(90)
    got = received()[n:]
    print([title(m) for m in got])
    assert len(got) == 1, got
    pings(got[0])
    # Test-only tolerance: under emulation cAdvisor may also have failed at boot, killed by
    # Docker's restart while it started (it is part of docker.service); the
    # notifier then counts the failures it held back in the title.
    assert re.fullmatch(
        re.escape(f"{PING}**🔴 nuc: cadvisor.service failed")
        + r"( \(\d+ more times since the last message, not posted\))?\*\*",
        title(got[0]),
    ), got
    nuc.succeed("systemctl start cadvisor.service")
    nuc.wait_for_unit("cadvisor.service")
    # Nothing on the way back either: no TargetDown, no resolved post.
    time.sleep(75)
    assert received()[n + 1 :] == [], received()[n + 1 :]

with subtest("3. DiskFilling: a file past the threshold posts, its removal resolves"):
    # Measured as node-exporter does (statfs: size and the space available
    # to users), so the fill takes / to 60 %, over the test's 50 %.
    size, avail = map(int, nuc.succeed("df -B1 --output=size,avail / | tail -n 1").split())
    used = 100 * (1 - avail / size)
    print(f"/ is {used:.1f} % used of {size} bytes")
    assert used < 40, f"/ is already {used:.1f} % used; the test's threshold is 50 %"
    fill = int((0.60 - used / 100) * size)
    disk = re.compile(r"Disk / is \d+% full \(threshold 50% for 15s\)")
    n = len(received())
    nuc.succeed(f"fallocate -l {fill} /var/fill")
    print(nuc.succeed("df -h /"))
    msg = wait_post(re.compile(re.escape(PING) + r"\*\*🔴 nuc: " + disk.pattern + r"\*\*"), n)
    pings(msg)
    nuc.succeed("rm /var/fill")
    msg = wait_post(re.compile(r"\*\*✅ nuc: resolved: " + disk.pattern + r"\*\*"), n)
    quiet(msg)
    assert len(received()) == n + 2, received()[n:]

with subtest("5. OomKill and StackMemoryNearLimit: a container past its slice's limit"):
    slice_id = "/stack.slice/stack-oomtest.slice"
    nuc.succeed(f"docker load < {IMAGE}")
    nuc.succeed(
        "docker run -d --name oomtest --cgroup-parent stack-oomtest.slice"
        " --tmpfs /fill:size=100m oomtest:test"
    )
    pid = nuc.succeed("docker inspect -f '{{.State.Pid}}' oomtest").strip()
    cgroup = nuc.succeed(f"cat /proc/{pid}/cgroup").strip()
    print(cgroup)
    assert f"0::{slice_id}/docker-" in cgroup, cgroup
    limit = nuc.succeed(f"cat /sys/fs/cgroup{slice_id}/memory.max").strip()
    assert limit == str(64 * 1024 * 1024), limit
    # cAdvisor must have the container's counter, at 0, before the kill:
    # increase() needs a sample from before it.
    q = "container_oom_events_total%7Bname%3D%22oomtest%22%7D"
    nuc.wait_until_succeeds(
        f"curl -fsS 'http://127.0.0.1:9090/api/v1/query?query={q}' | grep -q oomtest",
        timeout=180,
    )
    time.sleep(20)

    # 59 of the slice's 64 MiB in a tmpfs: the kernel cannot reclaim it
    # (no swap), so the slice stays near its limit.
    near = re.compile(
        re.escape(f"Stack slice {slice_id} uses ") + r"\d+% of its memory limit \(threshold 90% for 15s\)"
    )
    n = len(received())
    nuc.succeed("docker exec oomtest dd if=/dev/zero of=/fill/a bs=1M count=59")
    msg = wait_post(re.compile(re.escape(PING) + r"\*\*🔴 nuc: " + near.pattern + r"\*\*"), n)
    pings(msg)

    # Freed from the host side, through the container's root: a docker exec
    # would need memory the slice no longer has (runc's init was the one
    # killed when tried).
    m = len(received())
    nuc.succeed(f"rm /proc/{pid}/root/fill/a")
    msg = wait_post(re.compile(r"\*\*✅ nuc: resolved: " + near.pattern + r"\*\*"), m)
    quiet(msg)
    assert len(received()) == m + 1, received()[m:]

    # tail keeps the whole of an endless line: it grows until killed.
    oom = "Out-of-memory kill in container oomtest"
    m = len(received())
    rc = nuc.execute("docker exec oomtest tail /dev/zero")[0]
    print("tail exited with", rc)
    assert rc != 0, rc
    events = nuc.succeed(f"cat /sys/fs/cgroup{slice_id}/memory.events")
    print(events)
    assert re.search(r"^oom_kill [1-9]", events, re.M), events
    nuc.succeed("docker inspect -f '{{.State.Running}}' oomtest | grep -qx true")
    check_fired(oom, m)
    # One post, though the counter is also raised in the slice, in
    # stack.slice and at the root.
    time.sleep(60)
    assert [title(x) for x in received()[m:]] == [firing(oom)], received()[m:]

    # The rule looks at the last 5 minutes, and a range keeps the samples
    # from before the container's series went stale, so the alert resolves
    # once the kill is 5 minutes old, plus keep_firing_for's 2 (seen: not
    # within 300 s of the container's removal).
    nuc.succeed("docker rm -f oomtest")
    check_resolved(oom, m, timeout=720)
    assert len(received()) == m + 2, received()[m:]

with subtest("6. two alerts firing, one resolving: the other is not posted again"):
    amtool = f"amtool --alertmanager.url={AM}"
    # GapControl (tests/alerting.nix) is UnitFailed without keep_firing_for,
    # the negative control for the scrape gap below. Silenced throughout, so
    # it never posts.
    nuc.succeed(
        f"{amtool} silence add alertname=GapControl --duration 2h"
        " --author test --comment 'negative control'"
    )
    n = len(received())
    nuc.succeed("systemd-run --unit fail-a false")
    nuc.succeed("systemd-run --unit fail-b false")
    check_fired(unit_failed("fail-a"), n)
    check_fired(unit_failed("fail-b"), n)
    nuc.succeed("systemctl reset-failed fail-a.service")
    check_resolved(unit_failed("fail-a"), n)

    # A missed scrape of node-exporter, as a deploy that restarts it can
    # cause: fail-b's series goes stale, and its alert must ride that out
    # (keep_firing_for in rules.nix) rather than resolve and post again.
    # TargetDown is silenced meanwhile: the gap itself is not what this
    # checks, and it may last past TargetDown's 30 s.
    gap_silence = nuc.succeed(
        f"{amtool} silence add alertname=TargetDown --duration 10m"
        " --author test --comment 'scrape gap'"
    ).strip()
    held_since = wait_active_at("UnitFailed", "fail-b.service")
    control_since = wait_active_at("GapControl", "fail-b.service")
    print("before the gap:", held_since, control_since)
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    deadline = time.monotonic() + 120
    while not prom('up{job="node"} == 0'):
        assert time.monotonic() < deadline, "no failed scrape of node-exporter"
        time.sleep(1)
    # The control has gone with the series: the gap is long enough to drop
    # an alert that does not ride it out.
    deadline = time.monotonic() + 120
    while active_at("GapControl", "fail-b.service") is not None:
        assert time.monotonic() < deadline, "GapControl survived the gap"
        time.sleep(1)
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    deadline = time.monotonic() + 120
    while not prom('up{job="node"} == 1'):
        assert time.monotonic() < deadline, "node-exporter not scraped again"
        time.sleep(1)
    # The control fires again as a new alert; UnitFailed is the same alert
    # it was before the gap, never resolved.
    control_after = wait_active_at("GapControl", "fail-b.service")
    held_after = active_at("UnitFailed", "fail-b.service")
    print("after the gap:", held_after, control_after)
    assert control_after != control_since, (control_since, control_after)
    assert held_after == held_since, (held_since, held_after)

    # Two more group intervals (1 minute here) for a re-post to show up.
    time.sleep(150)
    wait_am("TargetDown", lambda s: s is None)
    nuc.succeed(f"{amtool} silence expire {gap_silence}")
    assert len(matching(firing(unit_failed("fail-b")), n)) == 1, received()[n:]
    assert len(received()) == n + 3, received()[n:]
    nuc.succeed("systemctl reset-failed fail-b.service")
    check_resolved(unit_failed("fail-b"), n)
    assert len(received()) == n + 4, received()[n:]

with subtest("7. a silence stops the post"):
    amtool = f"amtool --alertmanager.url={AM}"
    silence = nuc.succeed(
        f"{amtool} silence add alertname=TargetDown --duration 10m"
        " --author test --comment 'alerting test'"
    ).strip()
    print("silence", silence)
    n = len(received())
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    # The alert fires, and is silenced: so the missing post is the silence's
    # doing, not a quiet rule.
    state = wait_am("TargetDown", lambda s: s is not None and s["silencedBy"])
    assert state["state"] == "suppressed", state
    time.sleep(60)
    assert received()[n:] == [], received()[n:]
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    wait_am("TargetDown", lambda s: s is None)
    nuc.succeed(f"{amtool} silence expire {silence}")
    # Resolved while silenced, never posted: nothing to say it resolved.
    time.sleep(75)
    assert received()[n:] == [], received()[n:]

with subtest("8. a post that fails while Discord is down arrives once it is back"):
    n = len(received())
    nuc.succeed("systemctl stop webhook-receiver.service")
    nuc.succeed("systemd-run --unit fail-outage false")
    time.sleep(30)
    # The relay tried, and failed (the alert takes up to a scrape, an
    # evaluation and group_wait to get there).
    nuc.wait_until_succeeds(
        "journalctl -u alert-relay -o cat --no-pager | grep -F 'post of UnitFailed failed'",
        timeout=180,
    )
    nuc.succeed("systemctl start webhook-receiver.service")
    check_fired(unit_failed("fail-outage"), n)
    # Once: no retry of a post that went through.
    time.sleep(90)
    assert len(received()) == n + 1, received()[n:]
    nuc.succeed("systemctl reset-failed fail-outage.service")
    check_resolved(unit_failed("fail-outage"), n)

with subtest("9. Alertmanager, the relay and the blackbox exporter listen on loopback only"):
    tcp = nuc.succeed("ss -ltnH")
    udp = nuc.succeed("ss -lunH")
    print(tcp, udp)
    for port in (9093, 9095, 9115):
        local = [
            line.split()[3]
            for line in tcp.splitlines()
            if line.split()[3].rsplit(":", 1)[1] == str(port)
        ]
        assert local, f"nothing listens on {port}"
        assert all(addr == f"127.0.0.1:{port}" for addr in local), local
    # Alertmanager's cluster port, TCP and UDP.
    for listing in (tcp, udp):
        ports = [line.split()[3].rsplit(":", 1)[1] for line in listing.splitlines()]
        assert "9094" not in ports, listing

with subtest("10. the webhook URL is not in the journal"):
    nuc.succeed("journalctl --sync")
    # Saved first, so a failing journalctl cannot pass as "not found".
    nuc.succeed("journalctl --no-pager -o cat > /tmp/journal.txt")
    assert int(nuc.succeed("wc -l < /tmp/journal.txt")) > 1000
    nuc.fail(f"grep -F {SECRET} /tmp/journal.txt")
