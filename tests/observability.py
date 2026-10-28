# Test script for tests/observability.nix. `nuc` and `lan` are the test
# driver's machines; LAN_IP and PYTHON are defined by the Nix file in front of
# this script.
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
    nuc.wait_for_unit("probe.service")
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

with subtest("everything listens on loopback"):
    listeners = nuc.succeed("ss -ltnH")
    print(listeners)
    for port in (9090, 9100, 8081):
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
