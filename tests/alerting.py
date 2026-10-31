# The helpers both halves of tests/alerting.nix share, and their start: the
# Nix file puts this after its constants and before the half's own script
# (alerting-a.py or alerting-b.py). `nuc` is the test driver's machine;
# SECRET, ROLE, GATEWAY and IMAGE are defined by the Nix file, and so are the
# timings below, in seconds.
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

# Every fixed sleep in the halves is made of these, never a bare number, so
# that a change to one timing in tests/alerting.nix moves every wait sized
# around it:
#
#   SCRAPE           how often each exporter is scraped (the host's)
#   EVALUATION       how often Prometheus evaluates the rules (the test's)
#   GROUP_WAIT       how long a new alert's first post waits (the host's)
#   GROUP_INTERVAL   how long a later post of the same group waits (the test's)
#   GRACE            how long a firing alert rides out a gap (the test's)
#   SLACK            the VM's own delays on top
#   TARGET_DOWN_FOR  TargetDown's `for` (the test's)


def to_post(for_):
    """Seconds, at most, from a condition starting to its first post, for
    an alert whose `for` is for_ seconds: the scrape that sees it, the
    evaluation that starts the `for`, the `for`, the evaluation that ends it,
    and Alertmanager's group_wait."""
    return SCRAPE + EVALUATION + for_ + EVALUATION + GROUP_WAIT


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


def posts_since(since):
    """What a failed count of posts reports, in a few lines: CI shows only
    the last lines of a failed test's log, not the journal above them
    (#185). Each post from the since-th on, with when the receiver wrote it,
    then what Alertmanager and the relay last logged about posting."""
    out = nuc.shared_dir / "webhook"
    lines = []
    for f in sorted(out.glob("*.json"))[since:]:
        when = datetime.datetime.fromtimestamp(f.stat().st_mtime, datetime.timezone.utc)
        lines.append(f"{when:%H:%M:%S} {title(unstamped(json.loads(f.read_text())))}")
    # Alertmanager logs a failed notification at WARN; the relay logs each
    # post and how long it took, and the sender under it (curl) its errors.
    log = nuc.execute(
        "journalctl -u alertmanager -u alert-relay -o short-iso --no-pager"
        " | grep -E 'level=(WARN|ERROR)|post of|curl:' | tail -n 8"
    )[1]
    return "\n".join(["posts:", *lines, "log:", log.strip() or "none"])


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


def settle():
    """Wait until every target is scraped, Alertmanager holds no alert, and
    no post has arrived for a group interval: then nothing set off before
    is still on its way."""
    deadline = time.monotonic() + 600
    while prom("up == 0") or am_alerts():
        assert time.monotonic() < deadline, (prom("up == 0"), am_alerts())
        time.sleep(1)
    # A resolve is posted at its group's next flush.
    still = GROUP_INTERVAL + SLACK
    while True:
        n = len(received())
        time.sleep(still)
        if len(received()) == n:
            break
        assert time.monotonic() < deadline, [title(m) for m in received()]
    print("settled:", [title(m) for m in received()])


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


def loopback_only():
    """Subtest 9, run by both halves: it reads only the configuration."""
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


def webhook_not_in_journal():
    """Subtest 10, run last by both halves, so that it reads the journal of
    every post (and failed post) that half made."""
    nuc.succeed("journalctl --sync")
    # Saved first, so a failing journalctl cannot pass as "not found".
    nuc.succeed("journalctl --no-pager -o cat > /tmp/journal.txt")
    assert int(nuc.succeed("wc -l < /tmp/journal.txt")) > 1000
    nuc.fail(f"grep -F {SECRET} /tmp/journal.txt")
