# Test script for tests/docker.nix. `nuc`, `lan` and `far` are the test
# driver's machines; IMAGE, COMPOSE and the addresses are defined by the Nix
# file in front of it.

import json
import time


def listeners(port):
    """The addresses something listens on for TCP `port`, from ss."""
    out = nuc.succeed(f"ss -Htln 'sport = :{port}'")
    return sorted({line.split()[3].rsplit(":", 1)[0] for line in out.splitlines()})


def published(port):
    """Wait for `port` to be published, then return its addresses."""
    nuc.wait_until_succeeds(f"ss -Htln 'sport = :{port}' | grep -q .", timeout=60)
    return listeners(port)


def restart_daemon(name, port):
    """Restart dockerd with container `name` publishing `port` to the LAN,
    while `lan` polls the port every 0.1 s. Return whether the container
    kept its process, and the poll's failures out of its attempts."""
    pid = nuc.succeed(f"docker inspect -f '{{{{.State.Pid}}}}' {name}").strip()
    lan.succeed(
        f"(for i in $(seq 150); do curl -s -o /dev/null --max-time 1 -w '%{{http_code}}\\n' "
        f"http://{NUC_LAN}:{port}/hostname || true; sleep 0.1; done > /tmp/poll) >/dev/null 2>&1 &"
    )
    time.sleep(2)
    nuc.succeed("systemctl restart docker.service")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)
    lan.wait_until_succeeds("test $(wc -l < /tmp/poll) -ge 150", timeout=240)
    codes = lan.succeed("cat /tmp/poll").split()
    failures = sum(c != "200" for c in codes)
    after = nuc.succeed(f"docker inspect -f '{{{{.State.Running}}}} {{{{.State.Pid}}}}' {name}").split()
    # The poll as runs, e.g. 200x40 000x4 200x106: where the gap fell.
    runs = []
    for c in codes:
        if runs and runs[-1][0] == c:
            runs[-1][1] += 1
        else:
            runs.append([c, 1])
    print(f"{name}: pid {pid} -> {after}; polls " + " ".join(f"{c}x{n}" for c, n in runs))
    return after == ["true", pid], failures, len(codes)


def switch(name):
    """Switch to specialisation `name`, or back to the host with None, and
    wait for Docker to come back with the new settings."""
    top = "/run/booted-system" + (f"/specialisation/{name}" if name else "")
    nuc.succeed(f"{top}/bin/switch-to-configuration test")
    nuc.wait_for_unit("docker.service")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)


start_all()
nuc.wait_for_unit("docker.service")
for m in (lan, far):
    m.wait_for_unit("static-web-server.service")
    m.wait_for_open_port(80)

with subtest("nobody is in the docker group, and ops needs sudo"):
    members = nuc.succeed("getent group docker").strip().split(":")[3]
    assert members == "", f"docker group members: {members!r}"
    assert "docker" not in nuc.succeed("id -nG ops").split()
    out = nuc.fail("runuser -u ops -- docker info 2>&1")
    assert "permission denied" in out, out

with subtest("the image loads, and sudo docker runs it"):
    nuc.succeed(f"docker load < {IMAGE}")
    out = nuc.succeed("runuser -u ops -- sudo docker run --rm probe:test echo hello-from-a-container")
    assert out.strip() == "hello-from-a-container", out

with subtest("daemon: data root, journald logs, live-restore on"):
    info = json.loads(nuc.succeed("docker info --format '{{json .}}'"))
    assert info["DockerRootDir"] == "/var/lib/docker", info["DockerRootDir"]
    assert info["LoggingDriver"] == "journald", info["LoggingDriver"]
    assert info["LiveRestoreEnabled"] is True, info["LiveRestoreEnabled"]
    # The VM's disk is not btrfs, so this is not the nuc's driver; the nuc's
    # is recorded in docs/runbooks/docker.md.
    print(f"storage driver in the VM: {info['Driver']}")

with subtest("no-new-privileges is on in every container"):
    out = nuc.succeed("docker run --rm probe:test grep NoNewPrivs /proc/self/status")
    assert out.split() == ["NoNewPrivs:", "1"], out
    # The per-container opt-out the runbook offers.
    out = nuc.succeed(
        "docker run --rm --security-opt no-new-privileges=false probe:test grep NoNewPrivs /proc/self/status"
    )
    assert out.split() == ["NoNewPrivs:", "0"], out

with subtest("container output reaches the journal"):
    nuc.succeed("docker run --name logprobe probe:test echo marker-in-the-journal")
    nuc.wait_until_succeeds(
        "journalctl CONTAINER_NAME=logprobe | grep -q marker-in-the-journal", timeout=30
    )
    nuc.succeed("docker rm logprobe")

with subtest("a bare docker run publishes on loopback only"):
    nuc.succeed("docker run -d --name bare -p 8080:8080 probe:test")
    assert published(8080) == ["127.0.0.1"], listeners(8080)
    nuc.succeed("curl -sf http://127.0.0.1:8080/hostname")

with subtest("so does a network created afterwards"):
    nuc.succeed("docker network create made")
    nuc.succeed("docker run -d --name onmade --network made -p 8081:8080 probe:test")
    assert published(8081) == ["127.0.0.1"], listeners(8081)

with subtest("and a Compose project's own network"):
    nuc.succeed(f"docker compose -p probe -f {COMPOSE} up -d")
    assert published(8082) == ["127.0.0.1"], listeners(8082)
    nuc.succeed(f"docker compose -p probe -f {COMPOSE} down")

with subtest("prune runs weekly"):
    nuc.succeed("systemctl is-active docker-prune.timer")
    cal = nuc.succeed("systemctl show docker-prune.timer -p TimersCalendar --value")
    # systemd stores "weekly" expanded.
    assert "OnCalendar=Mon *-*-* 00:00:00" in cal, cal
    # What the runbook says it removes: no --all (tagged images) and no
    # --volumes.
    cmd = nuc.succeed("systemctl show docker-prune.service -p ExecStart --value")
    assert "system prune -f" in cmd, cmd
    assert "--all" not in cmd and "--volumes" not in cmd, cmd

with subtest("Docker turns forwarding on and leaves its FORWARD policy at accept"):
    # Why the firewall filters forwarded traffic (modules/base/firewall.nix).
    assert nuc.succeed("cat /proc/sys/net/ipv4/ip_forward").strip() == "1"
    policy = nuc.succeed("iptables -S FORWARD | head -1").strip()
    assert policy == "-P FORWARD ACCEPT", policy

with subtest("a port published on 0.0.0.0 is reachable from the LAN"):
    nuc.succeed("docker run -d --name public -p 0.0.0.0:8090:8080 probe:test")
    published(8090)
    lan.succeed(f"curl -sf --max-time 10 http://{NUC_LAN}:8090/hostname")
    # And one published without an address is not.
    lan.fail(f"curl -sf --max-time 5 http://{NUC_LAN}:8081/hostname")

with subtest("containers reach the LAN, from the built-in and a created network"):
    for net in ("bridge", "made"):
        out = nuc.succeed(f"docker run --rm --network {net} probe:test wget -qO- http://{LAN}/")
        assert out.strip() == "lan", (net, out)

with subtest("containers on one network reach each other by name"):
    nuc.succeed("docker run -d --name peer --network made probe:test")
    out = nuc.succeed("docker run --rm --network made probe:test wget -qO- http://peer:8080/hostname")
    assert out.strip(), out
    nuc.succeed("docker rm -f peer")

with subtest("the nuc does not route between its networks"):
    lan.fail(f"curl -sf --max-time 5 http://{FAR}/")
    far.fail(f"curl -sf --max-time 5 http://{LAN}/")

with subtest("live-restore: a container outlives a daemon restart"):
    nuc.succeed("docker run -d --name live -p 0.0.0.0:8091:8080 probe:test")
    published(8091)
    kept, failures, polls = restart_daemon("live", 8091)
    assert kept, "the container did not keep running"
    # New connections from the LAN fail for a moment while the daemon
    # restarts; the number is printed, not asserted, since emulation
    # stretches it. The port must answer again afterwards.
    lan.succeed(f"curl -sf --max-time 10 http://{NUC_LAN}:8091/hostname")

with subtest("control: without default-network-opts, a new network binds everywhere"):
    switch("noNetworkDefault")
    nuc.succeed("docker network create later")
    nuc.succeed("docker run -d --name onlater --network later -p 8083:8080 probe:test")
    assert "0.0.0.0" in published(8083), listeners(8083)
    # A network keeps the address it was created with (docs/runbooks/docker.md):
    # `onmade`, kept running through the daemon restart by live-restore, is
    # still on loopback.
    nuc.succeed("docker start onmade")
    assert published(8081) == ["127.0.0.1"], listeners(8081)
    # `ip` is unchanged, so the built-in network is still on loopback.
    nuc.succeed("docker rm -f bare")
    nuc.succeed("docker run -d --name bare -p 8080:8080 probe:test")
    assert published(8080) == ["127.0.0.1"], listeners(8080)

with subtest("control: without ip, a bare docker run binds everywhere"):
    switch("noIp")
    # With live-restore, a daemon that starts while any container runs, on
    # any network, does not reconfigure the built-in network ("there are
    # running containers, updated network configuration will not take
    # affect", moby's daemon_unix.go), so it keeps its old address.
    nuc.succeed("docker rm -f bare")
    nuc.succeed("docker run -d --name bare -p 8080:8080 probe:test")
    assert published(8080) == ["127.0.0.1"], listeners(8080)
    # With every container stopped, the next daemon start applies it.
    nuc.succeed("docker stop $(docker ps -q)")
    nuc.succeed("docker rm bare")
    nuc.succeed("systemctl restart docker.service")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)
    nuc.succeed("docker run -d --name bare -p 8080:8080 probe:test")
    assert "0.0.0.0" in published(8080), listeners(8080)
    # The network default is back, so a new network is on loopback again.
    nuc.succeed("docker network create again")
    nuc.succeed("docker run -d --name onagain --network again -p 8084:8080 probe:test")
    assert published(8084) == ["127.0.0.1"], listeners(8084)

with subtest("control: without the forward filter, the LAN routes through the nuc"):
    switch("noForwardFilter")
    out = lan.succeed(f"curl -sf --max-time 10 http://{FAR}/")
    assert out.strip() == "far", out

with subtest("control: without live-restore, a daemon restart stops the container"):
    switch("noLiveRestore")
    nuc.succeed("docker run -d --name unkept -p 0.0.0.0:8092:8080 probe:test")
    published(8092)
    kept, failures, polls = restart_daemon("unkept", 8092)
    assert not kept, "the container survived without live-restore"
    assert failures > 0, "no poll failed without live-restore"
