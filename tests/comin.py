# Test script for tests/comin.nix. `nuc` is the test driver's machine; REPO and
# REAL_URL are defined by the Nix file in front of this script.
import json
import time

GIT = "git -c user.name=test -c user.email=test@example.invalid"


def status():
    out = nuc.succeed("comin status --json")
    return json.loads(out)["fetcher"]["git_repository_status"]


def commit(branch, message):
    nuc.succeed(
        f"cd /root/work && git checkout -q -B {branch} && "
        f"{GIT} commit -q --allow-empty -m '{message}' && "
        f"git push -q -f origin {branch}"
    )
    return nuc.succeed("git -C /root/work rev-parse HEAD").strip()


def fetched_at():
    return [r["fetched_at"] for r in status()["remotes"]]


nuc.wait_for_unit("multi-user.target")

with subtest("comin is running after boot"):
    nuc.wait_for_unit("comin.service")
    nuc.succeed("comin status")

with subtest("the metrics exporter listens on loopback only"):
    nuc.wait_until_succeeds("ss -Htln 'sport = :4243' | grep -q .", timeout=30)
    out = nuc.succeed("ss -Htln 'sport = :4243'")
    print(out)
    addrs = [line.split()[3] for line in out.splitlines() if line.strip()]
    assert addrs == ["127.0.0.1:4243"], addrs
    # And no other TCP port: comin's configuration still has an API server
    # address, unused in 0.14, which a later version could start listening on.
    pid = nuc.succeed("systemctl show -P MainPID comin").strip()
    assert pid not in ("", "0"), pid
    comin_tcp = nuc.succeed(f"ss -Htlnp | grep -F 'pid={pid},' || true")
    print(comin_tcp)
    assert len(comin_tcp.strip().splitlines()) == 1, comin_tcp

with subtest("the real configuration pulls the public repository over HTTPS"):
    # The test VM's remote is local; this is the URL the nuc uses.
    assert REAL_URL.startswith("https://github.com/"), REAL_URL

nuc.succeed(
    f"git init -q --bare -b main {REPO} && "
    f"git clone -q {REPO} /root/work"
)
main_sha = commit("main", "a commit on main")

with subtest("comin fetches main"):
    nuc.wait_until_succeeds(
        "comin status --json | grep -q " + main_sha, timeout=60
    )
    s = status()
    print(json.dumps(s, indent=2))
    assert s["selected_commit_id"] == main_sha, s
    assert s["selected_branch_name"] == "main", s

with subtest("a testing-nuc branch on top of main is ignored"):
    testing_sha = commit("testing-nuc", "a commit nobody reviewed")
    # Wait for two more fetches after the push, so comin has seen the branch.
    before = fetched_at()
    deadline = time.monotonic() + 60
    seen = 0
    while seen < 2:
        assert time.monotonic() < deadline, "comin stopped fetching"
        time.sleep(1)
        now = fetched_at()
        if now != before:
            seen += 1
            before = now
    s = status()
    print(json.dumps(s, indent=2))
    assert s["selected_commit_id"] == main_sha, s
    assert not s["selected_branch_is_testing"], s
    assert testing_sha not in json.dumps(s), s
