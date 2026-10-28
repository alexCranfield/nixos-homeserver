# Test script for tests/observability.nix. `nuc` and `lan` are the test
# driver's machines; LAN_IP, PYTHON and GRAFANA_PASSWORD are defined by the Nix
# file in front of this script.
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


ALL_UP = {"node": "up", "cadvisor": "up", "comin": "up", "prometheus": "up"}

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
    # And back, for the subtests that follow.
    nuc.succeed(f"printf %s '{GRAFANA_PASSWORD}' > /run/grafana-test/password")
    nuc.succeed("systemctl restart grafana-admin-password.service")
    grafana("/api/user", user=ADMIN)

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
    print(nuc.succeed("systemctl show -P ConditionResult,Result grafana-secret-key"))
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
    for port in (9090, 9100, 8081, 3000):
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
    out = lan.succeed(f"nmap -Pn -p 3000,4243,8081,9090,9100 {LAN_IP}")
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
