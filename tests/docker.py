# Test script for tests/docker.nix. `nuc` is the test driver's machine; IMAGE
# and COMPOSE are defined by the Nix file in front of it.

import json


def listeners(port):
    """The addresses something listens on for TCP `port`, from ss."""
    out = nuc.succeed(f"ss -Htln 'sport = :{port}'")
    return sorted({line.split()[3].rsplit(":", 1)[0] for line in out.splitlines()})


def published(port):
    """Wait for `port` to be published, then return its addresses."""
    nuc.wait_until_succeeds(f"ss -Htln 'sport = :{port}' | grep -q .", timeout=60)
    return listeners(port)


def switch(name):
    """Switch to specialisation `name`, or back to the host with None, and
    wait for Docker to come back with the new settings."""
    top = "/run/booted-system" + (f"/specialisation/{name}" if name else "")
    nuc.succeed(f"{top}/bin/switch-to-configuration test")
    nuc.wait_for_unit("docker.service")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)


nuc.wait_for_unit("docker.service")

with subtest("nobody is in the docker group, and ops needs sudo"):
    members = nuc.succeed("getent group docker").strip().split(":")[3]
    assert members == "", f"docker group members: {members!r}"
    assert "docker" not in nuc.succeed("id -nG ops").split()
    nuc.fail("runuser -u ops -- docker info")

with subtest("the image loads, and sudo docker runs it"):
    nuc.succeed(f"docker load < {IMAGE}")
    out = nuc.succeed("runuser -u ops -- sudo docker run --rm probe:test echo hello-from-a-container")
    assert out.strip() == "hello-from-a-container", out

with subtest("daemon: data root, journald logs, live-restore off"):
    info = json.loads(nuc.succeed("docker info --format '{{json .}}'"))
    assert info["DockerRootDir"] == "/var/lib/docker", info["DockerRootDir"]
    assert info["LoggingDriver"] == "journald", info["LoggingDriver"]
    assert info["LiveRestoreEnabled"] is False, info["LiveRestoreEnabled"]
    # The VM's disk is not btrfs, so this is not the nuc's driver; the nuc's
    # is recorded in docs/runbooks/docker.md.
    print(f"storage driver in the VM: {info['Driver']}")

with subtest("no-new-privileges is on in every container"):
    out = nuc.succeed("docker run --rm probe:test grep NoNewPrivs /proc/self/status")
    assert out.split() == ["NoNewPrivs:", "1"], out

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

with subtest("control: without default-network-opts, a new network binds everywhere"):
    switch("noNetworkDefault")
    nuc.succeed("docker network create later")
    nuc.succeed("docker run -d --name onlater --network later -p 8083:8080 probe:test")
    assert "0.0.0.0" in published(8083), listeners(8083)
    # A network keeps the address it was created with (docs/runbooks/docker.md).
    # The daemon restart stopped `onmade`; started again, it is still on
    # loopback.
    nuc.succeed("docker start onmade")
    assert published(8081) == ["127.0.0.1"], listeners(8081)
    # `ip` is unchanged, so the built-in network is still on loopback.
    nuc.succeed("docker rm -f bare")
    nuc.succeed("docker run -d --name bare -p 8080:8080 probe:test")
    assert published(8080) == ["127.0.0.1"], listeners(8080)

with subtest("control: without ip, a bare docker run binds everywhere"):
    switch("noIp")
    nuc.succeed("docker rm -f bare")
    nuc.succeed("docker run -d --name bare -p 8080:8080 probe:test")
    assert "0.0.0.0" in published(8080), listeners(8080)
    # The network default is back, so a new network is on loopback again.
    nuc.succeed("docker network create again")
    nuc.succeed("docker run -d --name onagain --network again -p 8084:8080 probe:test")
    assert published(8084) == ["127.0.0.1"], listeners(8084)
