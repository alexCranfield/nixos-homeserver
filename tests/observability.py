# Test script for tests/observability.nix. `nuc` and `lan` are the test
# driver's machines; LAN_IP, PYTHON and GRAFANA_PASSWORD are defined by the Nix
# file in front of this script (DASHBOARD is the Game servers dashboard's JSON file).
#
# LAN: local area network. API: application programming interface. JSON:
# JavaScript Object Notation.
import json
import re
import time
import urllib.parse

PROM = "http://127.0.0.1:9090"


def prom_get(path):
    return json.loads(nuc.succeed(f"curl -fsS '{PROM}{path}'"))


def query(expr):
    q = urllib.parse.quote(expr, safe="")
    return prom_get(f"/api/v1/query?query={q}")["data"]["result"]


def target_health():
    targets = prom_get("/api/v1/targets")["data"]["activeTargets"]
    return {t["labels"]["job"]: t["health"] for t in targets}


def wait_for_health(want, timeout=120):
    # Prometheus marks a target up or down only after its next scrape, every
    # 15 seconds.
    deadline = time.monotonic() + timeout
    while True:
        health = target_health()
        if health == want:
            return health
        if time.monotonic() > deadline:
            raise AssertionError(f"targets {health}, wanted {want}")
        time.sleep(3)


GRAFANA = "http://127.0.0.1:3000"


def grafana(path, user=None, data=None, expect=200):
    # curl prints the status code last; -o keeps the body apart from it.
    auth = f"-u '{user}'" if user else ""
    body = f"-H 'Content-Type: application/json' -d '{json.dumps(data)}'" if data else ""
    status = nuc.succeed(
        f"curl -sS -o /tmp/grafana.out -w '%{{http_code}}' {auth} {body} '{GRAFANA}{path}'"
    ).strip()
    out = nuc.succeed("cat /tmp/grafana.out")
    assert status == str(expect), f"{path}: {status}, wanted {expect}: {out}"
    return json.loads(out) if out.strip() else None


ADMIN = f"admin:{GRAFANA_PASSWORD}"


def open_ports(out):
    return sorted(int(p) for p in re.findall(r"^(\d+)/tcp\s+open\b", out, re.M))


# The blackbox jobs are up whenever the exporter answers, whether or not the
# probe it runs succeeds.
ALL_UP = {
    "node": "up",
    "cadvisor": "up",
    "comin": "up",
    "prometheus": "up",
    "blackbox_gateway": "up",
    "blackbox_dns": "up",
}

start_all()
nuc.wait_for_unit("multi-user.target")
nuc.wait_for_unit("prometheus.service")
nuc.wait_for_open_port(9090)

with subtest("every scrape target is up"):
    print(wait_for_health(ALL_UP))

with subtest("negative control: a stopped exporter shows down"):
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    print(wait_for_health({**ALL_UP, "node": "down"}))
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    print(wait_for_health(ALL_UP))

with subtest("cAdvisor sees the test container by name"):
    # Under emulation (no KVM), Docker's containerd can time out on its first
    # start while everything else boots; Docker restarts itself, but the
    # probe's start has already failed on it. Start it once Docker is up.
    nuc.wait_for_unit("docker.service")
    nuc.succeed("systemctl start probe.service")
    deadline = time.monotonic() + 120
    while not (series := query('container_memory_usage_bytes{name="probe"}')):
        assert time.monotonic() < deadline, "no series for the probe container"
        time.sleep(5)
    print(series)
    names = query('count by (name) (container_last_seen{name!=""})')
    print(f"containers cAdvisor names: {[s['metric']['name'] for s in names]}")
    count = query('count({__name__=~"container_.*"})')
    print(f"cAdvisor series: {count[0]['value'][1]}")

with subtest("after a Docker restart, cAdvisor still names the container"):
    # A deploy that updates Docker restarts it; live-restore keeps the
    # container running (docs/runbooks/docker.md).
    before = nuc.succeed("systemctl show -P ExecMainStartTimestampMonotonic cadvisor")
    nuc.succeed("systemctl restart docker.service")
    nuc.wait_for_unit("cadvisor.service")
    after = nuc.succeed("systemctl show -P ExecMainStartTimestampMonotonic cadvisor")
    assert before != after, "cAdvisor did not restart with Docker"
    # Seen in a scrape after the restart, not only before it.
    expr = 'time() - container_last_seen{name="probe"} < 30'
    deadline = time.monotonic() + 120
    while not (series := query(expr)):
        assert time.monotonic() < deadline, "probe not seen since the restart"
        time.sleep(5)
    print(series)

with subtest("node-exporter reports systemd units"):
    result = query('node_systemd_unit_state{name="sshd.service",state="active"}')
    print(result)
    assert [r["value"][1] for r in result] == ["1"], result

with subtest("probes and Tailscale state are scraped"):
    # Tailscale is not logged in here, so it is not running; the gauge must
    # still be there, as 0, rather than missing. Under emulation the first
    # timer run can take a while.
    deadline = time.monotonic() + 180
    while not (series := query("homeserver_tailscale_running")):
        assert time.monotonic() < deadline, "no homeserver_tailscale_running"
        time.sleep(5)
    print(series)
    assert [r["value"][1] for r in series] == ["0"], series
    health = query("homeserver_tailscale_health_messages")
    print(health)
    assert health, "no homeserver_tailscale_health_messages"
    # Whatever the probes find in this network, each job's target is the
    # exporter, which answers, and each probe reports a result.
    for job in ("blackbox_gateway", "blackbox_dns"):
        deadline = time.monotonic() + 120
        while not (up := query(f'up{{job="{job}"}} == 1')):
            assert time.monotonic() < deadline, f"{job} is not up"
            time.sleep(5)
        while not (probe := query(f'probe_success{{job="{job}"}}')):
            assert time.monotonic() < deadline, f"no probe_success for {job}"
            time.sleep(5)
        print(job, probe)
    nuc.wait_for_open_port(9115)

def minecraft_series():
    # What the Game servers dashboard draws, from its own JSON: the
    # expressions of the panels about the server, run through Prometheus.
    dash = json.load(open(DASHBOARD))
    out = {}
    for panel in dash["panels"]:
        if panel["title"] in ("Players online", "Server answering", "Response time"):
            # Players online has the count (refId A) and, as B, one series per
            # name; those are read by minecraft_names.
            out[panel["title"]] = [
                r["value"][1]
                for t in panel["targets"]
                if t["refId"] == "A"
                for r in query(t["expr"])
            ]
    return out


def minecraft_names():
    # The names the players panel draws, from its own B query: the label sets
    # Prometheus returns, so a name that is wrong shows up here.
    dash = json.load(open(DASHBOARD))
    (panel,) = [p for p in dash["panels"] if p["title"] == "Players online"]
    (target,) = [t for t in panel["targets"] if t["refId"] == "B"]
    assert target["legendFormat"] == "{{player}}", target
    return sorted(r["metric"]["player"] for r in query(target["expr"]))


def wait_for_names(want, timeout=180):
    deadline = time.monotonic() + timeout
    while (got := minecraft_names()) != want:
        assert time.monotonic() < deadline, f"wanted {want}, got {got}"
        time.sleep(5)
    return got


def wait_for_minecraft(want_players, timeout=180):
    deadline = time.monotonic() + timeout
    while True:
        got = minecraft_series()
        if got.get("Players online") == [want_players]:
            return got
        assert time.monotonic() < deadline, f"wanted {want_players} players, got {got}"
        time.sleep(5)


with subtest("the Minecraft player count reaches the dashboard's panels"):
    # Players online follows the server's own count, up to date within a
    # scrape; the other two panels have data. The names are checked below.
    got = wait_for_minecraft("3")
    print(got)
    assert got["Server answering"] == ["1"], got
    assert len(got["Response time"]) == 1 and 0 < float(got["Response time"][0]) < 10, got
    nuc.succeed("echo 5 > /run/fake-mc/players")
    print(wait_for_minecraft("5"))
    nuc.succeed("echo 0 > /run/fake-mc/players")
    print(wait_for_minecraft("0"))
    text = nuc.succeed("cat /var/lib/prometheus-node-exporter-text/minecraft.prom")
    print(text)
    # The one label is the player's name; the next subtest checks which.
    assert re.fullmatch(
        r'(#[^\n]*\n|homeserver_minecraft_\w+(\{player="\w+"\})? [0-9.]+\n)+', text
    ), text

with subtest("the player sample's names reach the players panel, and only valid ones"):
    # The stand-in lists five names: two valid, then one with a quote, one of
    # 20 characters and one with a newline, none a Minecraft name. Only the
    # first two may become series, and the count stays the server's own.
    print(wait_for_names(["TestPlayerOne", "TestPlayerTwo"]))
    text = nuc.succeed("cat /var/lib/prometheus-node-exporter-text/minecraft.prom")
    assert 'bad' not in text and 'WayToo' not in text and 'newline' not in text, text
    assert "homeserver_minecraft_players_online 0" in text, text
    # A sample that names nobody (a pack that hides it) leaves only the count.
    nuc.succeed("echo '[]' > /run/fake-mc/sample")
    print(wait_for_names([]))
    assert wait_for_minecraft("0")["Server answering"] == ["1"]
    nuc.succeed("echo '[\"TestPlayerOne\"]' > /run/fake-mc/sample")
    print(wait_for_names(["TestPlayerOne"]))
    # More than 12 valid names are cut to 12 (the first 12 in sorted order).
    many = [f"TestPlayer{i:02d}" for i in range(1, 16)]
    nuc.succeed(f"echo '{json.dumps(many)}' > /run/fake-mc/sample")
    print(wait_for_names(many[:12]))
    nuc.succeed("echo '[\"TestPlayerOne\", \"TestPlayerTwo\", \"bad\\\"name\"]' > /run/fake-mc/sample")
    print(wait_for_names(["TestPlayerOne", "TestPlayerTwo"]))

with subtest("the players graph sits with CPU, memory and network, on the same axis"):
    dash = json.load(open(DASHBOARD))
    grid = {p["title"]: p["gridPos"] for p in dash["panels"]}
    ids = [p["id"] for p in dash["panels"]]
    assert len(ids) == len(set(ids)), ids
    players, cpu = grid["Players online"], grid["CPU"]
    assert players["x"] == cpu["x"] and players["w"] == cpu["w"], (players, cpu)
    assert players["y"] + players["h"] == cpu["y"], (players, cpu)
    for title in ("Memory (working set, against the stack's limit)", "Network"):
        assert grid[title]["x"] == players["x"] and grid[title]["w"] == players["w"], title
    # The small panels sit above it, not beside it.
    for title in ("Server answering", "Response time"):
        assert grid[title]["y"] + grid[title]["h"] <= players["y"], title
    tip = [p for p in dash["panels"] if p["title"] == "Players online"][0]["options"]["tooltip"]
    assert tip["mode"] == "all", tip

with subtest("negative control: a server that stops answering shows down, with no count"):
    nuc.succeed("systemctl stop fake-minecraft.service")
    deadline = time.monotonic() + 120
    while (got := minecraft_series())["Server answering"] != ["0"]:
        assert time.monotonic() < deadline, got
        time.sleep(5)
    print(got)
    assert got["Players online"] == [] and got["Response time"] == [], got
    nuc.succeed("systemctl start fake-minecraft.service")
    wait_for_minecraft("3")

with subtest("negative control: with the exporter broken the panels have no data"):
    # The same check, against a timer that no longer writes: the file goes,
    # and the panels' queries come back empty, so the test above would fail.
    # A run already going when the timer stops would write the file again
    # after it is removed, so the test waits for it to finish. Stopping the
    # service instead would kill the run, fail the unit and post the failure.
    nuc.succeed("systemctl stop minecraft-status.timer")
    nuc.wait_until_succeeds(
        "! systemctl list-jobs --no-legend | grep -qF minecraft-status.service"
        " && [ $(systemctl show -P ActiveState minecraft-status.service) = inactive ]"
    )
    nuc.succeed("rm /var/lib/prometheus-node-exporter-text/minecraft.prom")
    deadline = time.monotonic() + 120
    while any((got := minecraft_series()).values()):
        assert time.monotonic() < deadline, got
        time.sleep(5)
    print(got)
    try:
        wait_for_minecraft("3", timeout=20)
    except AssertionError as e:
        print("failed as it should:", e)
    else:
        raise AssertionError("the check passed with the exporter stopped")
    nuc.succeed("systemctl start minecraft-status.timer")
    wait_for_minecraft("3")

with subtest("Grafana is healthy and requires a login"):
    nuc.wait_for_unit("grafana.service")
    nuc.wait_for_open_port(3000)
    print(grafana("/api/health"))
    grafana("/api/search", expect=401)

with subtest("the admin password works and a wrong one is refused"):
    print(grafana("/api/user", user=ADMIN))
    grafana("/api/user", user="admin:wrong", expect=401)

with subtest("the password follows its secret after the first start"):
    nuc.wait_for_unit("grafana-admin-password.service")
    # As sops-nix does when the secret changes: a new file, then a restart of
    # the unit (hosts/nuc/observability.nix).
    nuc.succeed("printf %s new-password > /run/grafana-test/password")
    nuc.succeed("systemctl restart grafana-admin-password.service")
    grafana("/api/user", user="admin:new-password")
    grafana("/api/user", user=ADMIN, expect=401)
    # Grafana's own reading of the file (its `$__file{}` provider) trims
    # spaces and newlines at both ends; the sync must agree with it, or the
    # first start and every later one would set different passwords.
    nuc.succeed("printf '  spaced-password \\n' > /run/grafana-test/password")
    nuc.succeed("systemctl restart grafana-admin-password.service")
    grafana("/api/user", user="admin:spaced-password")
    # A secret of more than one line is refused, not cut to its first line.
    nuc.succeed("printf 'first\\nsecond\\n' > /run/grafana-test/password")
    nuc.fail("systemctl restart grafana-admin-password.service")
    grafana("/api/user", user="admin:spaced-password")
    # And back, for the subtests that follow.
    nuc.succeed(f"printf %s '{GRAFANA_PASSWORD}' > /run/grafana-test/password")
    nuc.succeed("systemctl restart grafana-admin-password.service")
    grafana("/api/user", user=ADMIN)

with subtest("the password unit fails when Grafana isn't healthy"):
    # Rather than running the CLI against a database the server may still be
    # creating. Grafana is stopped (taking the unit with it), and the unit
    # started alone.
    nuc.succeed("systemctl stop grafana.service")
    nuc.fail("systemctl start grafana-admin-password.service")
    print(nuc.succeed("journalctl -u grafana-admin-password -b -n 3 -o cat"))
    nuc.succeed("systemctl start grafana.service")
    nuc.wait_for_unit("grafana-admin-password.service")
    grafana("/api/user", user=ADMIN)

with subtest("the oneshots give up, time out and so alert"):
    # A unit that retries for ever never reaches `failed`, so it never posts
    # (modules/base/notify.nix); one that hangs holds up a deploy.

    def prop(unit, name):
        return nuc.succeed(f"systemctl show -P {name} {unit}").strip()

    for unit in ("tailscale-serve-grafana", "grafana-admin-password"):
        timeout = prop(unit, "TimeoutStartUSec")
        print(unit, timeout)
        assert timeout != "infinity", (unit, timeout)
    # Serve: 5 attempts within 5 minutes, 5 s apart, so the limit is reached.
    serve = [
        prop("tailscale-serve-grafana", p)
        for p in ("StartLimitBurst", "StartLimitIntervalUSec", "RestartUSec")
    ]
    print(serve)
    assert serve == ["5", "5min", "5s"], serve

with subtest("the secret key was made once"):
    key = "/var/lib/grafana/secret_key"
    print(nuc.succeed(f"stat -c '%a %U %s' {key}"))
    assert nuc.succeed(f"stat -c '%a %U' {key}").strip() == "400 grafana"
    assert int(nuc.succeed(f"stat -c %s {key}")) >= 32
    before = nuc.succeed(f"sha256sum {key}")
    nuc.succeed("systemctl restart grafana.service")
    nuc.wait_for_open_port(3000)
    assert nuc.succeed(f"sha256sum {key}") == before, "the key changed"
    # The key unit is skipped once the key exists, and not failed.
    cond = nuc.succeed("systemctl show -P ConditionResult,Result grafana-secret-key").split()
    assert cond == ["no", "success"], cond
    grafana("/api/user", user=ADMIN)

with subtest("the data source is provisioned and healthy"):
    health = grafana("/api/datasources/uid/prometheus/health", user=ADMIN)
    print(health)
    assert health["status"] == "OK", health

with subtest("the three dashboards are in the nuc folder"):
    found = {
        d["title"]: d.get("folderTitle")
        for d in grafana("/api/search?type=dash-db", user=ADMIN)
    }
    print(found)
    want = {"Node Exporter Full", "cadvisor dashboard", "Game servers"}
    assert want <= set(found), found
    assert all(found[t] == "nuc" for t in want), found

with subtest("a query through Grafana returns data"):
    result = grafana(
        "/api/ds/query",
        user=ADMIN,
        data={
            "from": "now-5m",
            "to": "now",
            "queries": [
                {
                    "refId": "A",
                    "datasource": {"type": "prometheus", "uid": "prometheus"},
                    "expr": "node_load1",
                    "instant": True,
                }
            ],
        },
    )
    frames = result["results"]["A"]["frames"]
    print(frames)
    assert frames and frames[0]["data"]["values"], result

with subtest("Grafana does not phone home"):
    settings = grafana("/api/frontend/settings", user=ADMIN)
    # Grafana 13's frontend settings no longer carry reportingEnabled; the
    # running configuration below covers it.
    print(settings.get("newsFeedEnabled"), settings.get("buildInfo", {}).get("version"))
    assert settings.get("newsFeedEnabled") is False, settings.get("newsFeedEnabled")
    # The running configuration, as Grafana read it.
    analytics = grafana("/api/admin/settings", user=ADMIN)["analytics"]
    print(analytics)
    for key in ("check_for_updates", "check_for_plugin_updates", "reporting_enabled"):
        assert analytics[key] == "false", (key, analytics[key])

with subtest("everything listens on loopback"):
    listeners = nuc.succeed("ss -ltnH")
    print(listeners)
    for port in (9090, 9100, 9115, 9338, 3000):
        local = [
            line.split()[3]
            for line in listeners.splitlines()
            if line.split()[3].rsplit(":", 1)[1] == str(port)
        ]
        assert local, f"nothing listens on {port}"
        assert all(addr == f"127.0.0.1:{port}" for addr in local), local

with subtest("nothing new on the LAN"):
    # Nothing on `lan` pulls in network-online.target; reaching the nuc is
    # what matters.
    lan.wait_until_succeeds(f"ping -c 1 -W 2 {LAN_IP}", timeout=60)
    out = lan.succeed(f"nmap -Pn -p 3000,4243,9090,9100,9115,9338 {LAN_IP}")
    print(out)
    assert open_ports(out) == [], open_ports(out)

with subtest("negative control: the scan sees a port opened on the LAN"):
    nuc.succeed(
        f"systemd-run --unit lan-listener {PYTHON} -m http.server 8999 --bind {LAN_IP}"
    )
    nuc.wait_for_open_port(8999, addr=LAN_IP)
    nuc.succeed("nft add rule inet nixos-fw input-allow tcp dport 8999 accept")
    out = lan.succeed(f"nmap -Pn -p 8999 {LAN_IP}")
    print(out)
    assert open_ports(out) == [8999], open_ports(out)
