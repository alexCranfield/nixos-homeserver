# Test script for tests/compose-stack.nix. `nuc` and `client` are the test
# driver's machines; the addresses and ENV_RESTARTS are defined by the Nix
# file in front of it.

import json
import time


def containers(project):
    """{container name: (id, pid)} for the running containers of `project`."""
    out = nuc.succeed(
        f"docker ps -q --filter label=com.docker.compose.project={project}"
        " | xargs -r docker inspect -f '{{.Name}} {{.Id}} {{.State.Pid}}'"
    )
    return {n.lstrip("/"): (i, p) for n, i, p in (l.split() for l in out.splitlines())}


def wait_running(name):
    """Wait for container `name` to be running, not between restarts."""
    nuc.wait_until_succeeds(
        f"test \"$(docker inspect -f '{{{{.State.Running}}}} {{{{.State.Restarting}}}}' {name})\" = 'true false'",
        timeout=60,
    )


def curl(url):
    """curl's exit code fetching `url` from the client: 0 answered, 7
    refused, 28 timed out."""
    return client.execute(f"curl -s -o /dev/null --max-time 5 '{url}'")[0]


def listening(port, proto="t"):
    """The addresses the nuc listens on for `port`, TCP or (proto="u") UDP."""
    out = nuc.succeed(f"ss -Hln{proto} 'sport = :{port}'")
    return sorted({line.split()[3].rsplit(":", 1)[0] for line in out.splitlines()})


def crash_posts(name):
    """The posts so far about container `name` crashing, as message text."""
    files = nuc.succeed("ls /tmp/webhook | grep '[.]json$' || true").split()
    posts = [json.loads(nuc.succeed(f"cat /tmp/webhook/{f}"))["content"] for f in files]
    return [p for p in posts if f"{name} crashed" in p]


def kill(name):
    """Kill container `name`'s process as a crash would, and wait for Docker
    to restart it. Not `docker kill`, which Docker counts as stopping it on
    purpose, and does not restart."""
    nuc.succeed(f"kill -KILL $(docker inspect -f '{{{{.State.Pid}}}}' {name})")
    wait_running(name)


def switch(name):
    """Switch to specialisation `name`, or back to the host with None."""
    top = "/run/booted-system" + (f"/specialisation/{name}" if name else "")
    nuc.succeed(f"{top}/bin/switch-to-configuration test")


start_all()

with subtest("stacks start at boot and stay active"):
    nuc.wait_for_unit("stack-fixture.service")
    nuc.wait_for_unit("stack-other.service")
    assert containers("fixture"), "fixture runs no container"
    nuc.succeed("systemctl is-active stack-fixture.service")
    # Not started at boot.
    nuc.fail("systemctl is-active stack-unbound.service")

with subtest("files land in /etc/stacks, and .env is not in the store"):
    nuc.succeed("test -f /etc/stacks/fixture/compose.yml")
    nuc.succeed("test -f /etc/stacks/fixture/override.yml")
    env = nuc.succeed("readlink -f /etc/stacks/fixture/.env").strip()
    print(f".env -> {env}")
    assert env == "/run/secrets/fixture-env", env
    out = nuc.succeed("docker exec fixture-web-1 env")
    assert "GREETING=one" in out, out

with subtest("the env secret restarts its stack when it changes"):
    print(f"restartUnits: {ENV_RESTARTS}")
    assert "stack-fixture.service" in ENV_RESTARTS, ENV_RESTARTS

with subtest("containers sit in the stack's slice, restarting unless stopped"):
    out = nuc.succeed(
        "docker inspect -f '{{.HostConfig.CgroupParent}} {{.HostConfig.RestartPolicy.Name}}' fixture-web-1"
    ).split()
    print(f"cgroup parent, restart policy: {out}")
    assert out == ["stack-fixture.slice", "unless-stopped"], out
    pid = containers("fixture")["fixture-web-1"][1]
    cgroup = nuc.succeed(f"cat /proc/{pid}/cgroup").strip()
    print(f"cgroup: {cgroup}")
    assert "/stack-fixture.slice/" in cgroup, cgroup

with subtest("MemoryMax reaches the containers"):
    slice_dir = nuc.succeed("systemctl show -P ControlGroup stack-fixture.slice").strip()
    limit = nuc.succeed(f"cat /sys/fs/cgroup{slice_dir}/memory.max").strip()
    print(f"{slice_dir} memory.max: {limit}")
    assert limit == str(64 * 1024 * 1024), limit
    # tail keeps a line with no end in memory: 200 MB of it.
    code = nuc.execute("docker exec fixture-web-1 sh -c 'head -c 200m /dev/zero | tail > /dev/null'")[0]
    events = nuc.succeed(f"cat /sys/fs/cgroup{slice_dir}/memory.events")
    print(f"exit {code}; {events}")
    assert code != 0, code
    assert int(dict(l.split() for l in events.splitlines())["oom_kill"]) >= 1, events
    # The kernel picks what to kill in the slice, sometimes the web server
    # too; Docker then restarts the container.
    wait_running("fixture-web-1")

with subtest("a Docker restart leaves stacks up and their containers running"):
    before = containers("fixture")
    nuc.succeed("systemctl restart docker.service")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)
    nuc.succeed("systemctl is-active stack-fixture.service")
    after = containers("fixture")
    print(f"{before} -> {after}")
    assert after == before, (before, after)

with subtest("editing one stack restarts only that stack"):
    fixture, other = containers("fixture"), containers("other")
    switch("changed")
    nuc.wait_for_unit("stack-fixture.service")
    print(f"fixture {fixture} -> {containers('fixture')}; other {other} -> {containers('other')}")
    assert containers("fixture") != fixture
    assert containers("other") == other
    assert "EXTRA=two" in nuc.succeed("docker exec fixture-web-1 env")
    switch(None)
    nuc.wait_for_unit("stack-fixture.service")

with subtest("removing a stack stops it and takes its containers down"):
    switch("withoutOther")
    nuc.fail("systemctl is-active stack-other.service")
    left = nuc.succeed("docker ps -aq --filter label=com.docker.compose.project=other").strip()
    assert left == "", left
    switch(None)
    nuc.wait_for_unit("stack-other.service")

with subtest("the client reaches the declared port over IPv4, and it is logged"):
    nuc.wait_for_unit("stack-fixture.service")
    assert curl(f"http://{NUC}:8081/hostname") == 0
    nuc.wait_until_succeeds(
        f"journalctl -k --grep 'stack-port accept 8081/tcp' | grep -q 'SRC={CLIENT} '", timeout=30
    )

with subtest("a declared UDP port gets through, and is logged"):
    assert listening(8084, "u") == ["0.0.0.0"], listening(8084, "u")
    client.succeed(f"echo hi > /dev/udp/{NUC}/8084")
    nuc.wait_until_succeeds(
        f"journalctl -k --grep 'stack-port accept 8084/udp' | grep -q 'SRC={CLIENT} '", timeout=30
    )

with subtest("an undeclared port with no address binds loopback, and times out"):
    assert listening(8082) == ["127.0.0.1"], listening(8082)
    codes = curl(f"http://{NUC}:8082/"), curl(f"http://[{NUC6}]:8082/")
    print(f"8082 over IPv4, IPv6: curl exits {codes}")
    assert codes == (28, 28), codes

with subtest("an undeclared 0.0.0.0 port is dropped by the firewall, and logged"):
    assert listening(8083) == ["0.0.0.0"], listening(8083)
    assert curl(f"http://{NUC}:8083/") == 28
    # Logged after Docker's redirect, so the port shown is the container's.
    nuc.wait_until_succeeds(f"journalctl -k --grep 'stack-port drop' | grep -q 'SRC={CLIENT} '", timeout=30)

with subtest("a declared port that does not bind fails the unit"):
    nuc.fail("systemctl start stack-unbound.service")
    nuc.succeed("systemctl is-failed stack-unbound.service")
    nuc.succeed("journalctl -u stack-unbound.service --grep '8090/tcp'")

with subtest("allowedSources keeps everyone else out"):
    switch("restricted")
    assert curl(f"http://{NUC}:8081/hostname") == 28
    switch(None)
    assert curl(f"http://{NUC}:8081/hostname") == 0

with subtest("a removed stack's port is closed in the firewall"):
    switch("withoutFixture")
    table = nuc.succeed("nft list table inet stack-ports")
    assert "8081" not in table, table
    switch(None)
    nuc.wait_for_unit("stack-fixture.service")

with subtest("control: without default-network-opts, the no-address port binds everywhere"):
    switch("noNetworkDefault")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)
    # A network keeps the address it was created with: recreate it.
    nuc.succeed("systemctl restart stack-fixture.service")
    print(f"8082 listens on {listening(8082)}")
    assert listening(8082) == ["0.0.0.0", "[::]"], listening(8082)
    # The firewall still holds it: undeclared, and over IPv6 never forwarded.
    codes = curl(f"http://{NUC}:8082/"), curl(f"http://[{NUC6}]:8082/")
    print(f"8082 over IPv4, IPv6 without the default: curl exits {codes}")
    assert codes == (28, 28), codes
    switch(None)
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)
    nuc.succeed("systemctl restart stack-fixture.service")

with subtest("control: without the stack-ports table, the undeclared 0.0.0.0 port is reachable"):
    switch("noStackFirewall")
    assert curl(f"http://{NUC}:8083/") == 0
    switch(None)
    assert curl(f"http://{NUC}:8083/") == 28

with subtest("a crash restarts the container and posts quietly"):
    kill("other-web-1")
    nuc.wait_until_succeeds("grep -l 'other-web-1 crashed' /tmp/webhook/*.json", timeout=60)
    posts = crash_posts("other-web-1")
    print(f"posts: {posts}")
    assert len(posts) == 1, posts
    assert "(exit 137)" in posts[0] and "<@&" not in posts[0], posts[0]

with subtest("a third crash within the window pings, once"):
    kill("other-web-1")
    kill("other-web-1")
    nuc.wait_until_succeeds("test $(grep -l 'other-web-1 crashed' /tmp/webhook/*.json | wc -l) -ge 2", timeout=60)
    kill("other-web-1")
    time.sleep(10)
    posts = crash_posts("other-web-1")
    print(f"posts: {posts}")
    assert len(posts) == 2, posts
    assert posts[1].startswith(f"<@&{ROLE}>") and "3 times in 10 min" in posts[1], posts[1]

with subtest("stopping a stack is not a crash"):
    nuc.succeed("systemctl stop stack-other.service")
    nuc.succeed("systemctl start stack-other.service")
    nuc.succeed("systemctl is-active stack-other-watch.service")
    time.sleep(10)
    assert len(crash_posts("other-web-1")) == 2, crash_posts("other-web-1")

with subtest("the watcher survives a Docker restart"):
    # A fresh window, so the next crash posts again.
    nuc.succeed("rm /var/lib/stack-watch/other/other-web-1")
    restarts = int(nuc.succeed("systemctl show -P NRestarts stack-other-watch.service"))
    nuc.succeed("systemctl restart docker.service")
    nuc.wait_until_succeeds("docker info >/dev/null", timeout=60)
    nuc.wait_until_succeeds(
        f"test $(systemctl show -P NRestarts stack-other-watch.service) -gt {restarts}"
        " && systemctl is-active stack-other-watch.service",
        timeout=60,
    )
    time.sleep(5)
    kill("other-web-1")
    nuc.wait_until_succeeds("test $(grep -l 'other-web-1 crashed' /tmp/webhook/*.json | wc -l) -ge 3", timeout=60)
    posts = crash_posts("other-web-1")
    assert len(posts) == 3 and "<@&" not in posts[2], posts
