# Half b of tests/alerting.nix: subtests 2, 3 and 5, then 9 and 10, which
# both halves run. The helpers are in alerting.py, before this. The numbers
# are those of the test before it was split (#182), kept so that the
# history and the runbooks still name the same subtest.

# Subtest 2 counts every post from its start, so whatever boot set off must
# have posted first. Under emulation cAdvisor can fail at boot, more than
# once, and come up slowly enough for its TargetDown to fire (seen: it was
# scraped again only about 2 minutes after the units were up, and its
# TargetDown and resolve landed in subtest 2's count). In half a, subtest 4
# takes those minutes first.
settle()
# The notifier posts a unit's failure once per cooldown (10 minutes), and
# counts the rest. A boot-time failure of cAdvisor would hold back the post
# subtest 2 expects for its kill; in half a, minutes of other subtests pass
# first. Forget it, so that the post is this kill's (seen: held back, 303 s
# after the boot's).
cooldown = "/var/lib/notify-failure/cadvisor.service"
print("cAdvisor's cooldown state before:", nuc.execute(f"cat {cooldown}")[1].strip() or "none")
nuc.succeed(f"rm -f {cooldown}")

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
    # Long enough for cAdvisor's TargetDown to have posted, were it not held
    # back, and so for any UnitFailed too.
    time.sleep(to_post(TARGET_DOWN_FOR) + SLACK)
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
    # Nothing on the way back either: no TargetDown, no resolved post. A
    # TargetDown would follow a cAdvisor too slow to be scraped again.
    time.sleep(to_post(TARGET_DOWN_FOR) + SLACK)
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
    # One more scrape, and an evaluation, with the counter at 0.
    time.sleep(SCRAPE + EVALUATION)

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
    # stack.slice and at the root, all in the same scrape. That relies on
    # OomKill's matcher in rules.nix, `name!=""`: only a named container's
    # series qualifies, not the slices above it, which have no name. (Not
    # the `stack` regex, which only the stack alerts use.)
    time.sleep(to_post(0) + SLACK)
    assert [title(x) for x in received()[m:]] == [firing(oom)], received()[m:]

    # The rule looks at the last 5 minutes, and a range keeps the samples
    # from before the container's series went stale, so the alert resolves
    # once the kill is 5 minutes old, plus the grace (keep_firing_for; seen
    # with the 2 minutes of production: not within 300 s of the container's
    # removal).
    nuc.succeed("docker rm -f oomtest")
    check_resolved(oom, m, timeout=720)
    assert len(received()) == m + 2, received()[m:]

with subtest("9. Alertmanager, the relay and the blackbox exporter listen on loopback only"):
    loopback_only()

with subtest("10. the webhook URL is not in the journal"):
    webhook_not_in_journal()
