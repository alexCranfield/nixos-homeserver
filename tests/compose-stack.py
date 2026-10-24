# Test script for tests/compose-stack.nix. `nuc` and `client` are the test
# driver's machines; NUC and ENV_RESTARTS are defined by the Nix file in front
# of it.


def containers(project):
    """{container name: (id, pid)} for the running containers of `project`."""
    out = nuc.succeed(
        f"docker ps -q --filter label=com.docker.compose.project={project}"
        " | xargs -r docker inspect -f '{{.Name}} {{.Id}} {{.State.Pid}}'"
    )
    return {n.lstrip("/"): (i, p) for n, i, p in (l.split() for l in out.splitlines())}


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
