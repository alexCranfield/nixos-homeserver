# Ticket 6.7 (#197); see tests/tenant-net.nix for the machines.
import json

STAND_INS = {
    # namespace: (VM name, address)
    "tdev": ("tenant-dev", "10.88.0.2"),
    "trun": ("tenant-run", "10.88.0.3"),
}


def http(url, ns=None):
    """A curl command for url, from inside a stand-in's namespace if given.

    Any HTTP answer counts as reached, a 404 included: busybox's httpd has no
    index page to serve. Blocked means no answer at all.
    """
    cmd = f"curl -sS --max-time 5 -o /dev/null {url}"
    return f"ip netns exec {ns} {cmd}" if ns else cmd


def drops(chain):
    """Packets the tenant table has dropped in chain, from its named counter."""
    out = json.loads(nuc.succeed(f"nft -j list counter inet tenant-isolation {chain}-drops"))
    return next(o["counter"]["packets"] for o in out["nftables"] if "counter" in o)


def blocked(ns, url, chain):
    """url is unreachable from ns, and the tenant table is what dropped it."""
    before = drops(chain)
    nuc.fail(http(url, ns))
    after = drops(chain)
    assert after > before, (
        f"{url} from {ns} failed, but the table's {chain} counter stayed at "
        f"{before}: something else blocked it"
    )


def dig(ns, *args):
    return nuc.succeed(
        f"ip netns exec {ns} dig +short +time=3 +tries=1 {' '.join(args)} @{NUC_IP} probe.home.arpa"
    ).strip()


start_all()
for machine in (router, lan, internet):
    machine.wait_for_unit("web.service")
nuc.wait_for_unit("multi-user.target")
nuc.wait_for_unit("blocky.service")
nuc.wait_for_unit("stack-probe.service")
nuc.wait_for_open_port(OPEN_PORT)
nuc.wait_until_succeeds(http(f"http://{NUC_IP}:{PUBLISHED_PORT}/"))

with subtest("stand-ins get the taps' network from networkd"):
    for ns, (name, addr) in STAND_INS.items():
        tap = f"vm-{name}"
        nuc.succeed(
            f"ip netns add {ns}",
            f"ip link add {tap} type veth peer name eth0 netns {ns}",
            f"ip -n {ns} link set lo up",
            f"ip -n {ns} link set eth0 up",
            f"ip -n {ns} addr add {addr}/32 dev eth0",
            f"ip -n {ns} route add 10.88.0.1/32 dev eth0",
            f"ip -n {ns} route add default via 10.88.0.1 dev eth0 onlink",
        )
        nuc.wait_until_succeeds(f"ip -4 addr show dev {tap} | grep -qF 10.88.0.1/32")
        nuc.wait_until_succeeds(f"ip route show {addr} | grep -qF 'dev {tap}'")
        # IPv4 only: networkd gives the tap no IPv6 address, not even
        # link-local.
        nuc.fail(f"ip -6 addr show dev {tap} | grep -q inet6")
    # A web server inside one stand-in, as a VM the other must not reach.
    nuc.succeed(f"ip netns exec trun {BUSYBOX} httpd -p 80 -h /etc")
    nuc.wait_until_succeeds(http("http://10.88.0.3/"))

with subtest("negative controls: every target answers from outside the tenants"):
    lan.succeed(http(f"http://{ROUTER_IP}/"))
    lan.succeed(http(f"http://{NUC_IP}:{OPEN_PORT}/"))
    lan.succeed(http(f"http://{NUC_IP}:{PUBLISHED_PORT}/"))
    nuc.succeed(http(f"http://{LAN_IP}/"))
    nuc.succeed(http(f"http://{SHARED_IP}/"))
    nuc.succeed(http(f"http://{INTERNET_IP}/"))
    nuc.succeed(http("http://10.88.0.3/"))

for ns in STAND_INS:
    with subtest(f"{ns} reaches the internet and Blocky"):
        # `internet` routes only 192.168.1.0/24 back, so this also shows the
        # nuc masquerades the tenant network as its own address.
        nuc.succeed(http(f"http://{INTERNET_IP}/", ns))
        assert dig(ns) == "192.0.2.7", dig(ns)
        assert dig(ns, "+tcp") == "192.0.2.7", dig(ns, "+tcp")

    with subtest(f"{ns} reaches nothing else"):
        blocked(ns, f"http://{LAN_IP}/", "forward")
        blocked(ns, f"http://{ROUTER_IP}/", "forward")
        blocked(ns, f"http://{SHARED_IP}/", "forward")
        # Docker has rewritten the destination to the container's 172.x
        # address by the time the forward rules see it.
        blocked(ns, f"http://{NUC_IP}:{PUBLISHED_PORT}/", "forward")
        blocked(ns, f"http://{NUC_IP}:{OPEN_PORT}/", "input")
        blocked(ns, f"http://10.88.0.1:{OPEN_PORT}/", "input")

with subtest("one tenant never reaches the other"):
    blocked("tdev", "http://10.88.0.3/", "forward")

with subtest("Blocky logs the stand-ins by their VM names"):
    nuc.wait_until_succeeds(
        "test \"$(sudo -u postgres psql -At blocky -c "
        "\"SELECT count(DISTINCT client_name) FROM log_entries "
        "WHERE question_name LIKE 'probe.home.arpa%' "
        "AND client_name IN ('tenant-dev', 'tenant-run')\")\" = 2",
        timeout=90,
    )

with subtest("negative control: without the table, the same probes get through"):
    # The system to come back to: once switched, /run/current-system is the
    # specialisation.
    base = nuc.succeed("readlink -f /run/current-system").strip()
    nuc.succeed(f"{base}/specialisation/isolationOff/bin/switch-to-configuration test")
    nuc.fail("nft list table inet tenant-isolation")
    nuc.succeed(http(f"http://{LAN_IP}/", "tdev"))
    nuc.succeed(http(f"http://{NUC_IP}:{OPEN_PORT}/", "tdev"))
    # Not the other stand-in: NixOS's own forward rules drop that anyway,
    # accepting tenant traffic only on its way out of lan0.
    nuc.succeed(f"{base}/bin/switch-to-configuration test")
    nuc.succeed("nft list table inet tenant-isolation")
    blocked("tdev", f"http://{LAN_IP}/", "forward")

with subtest("negative control: tmpfiles' plain-directory fallback fails the check"):
    # tmpfiles `v` makes a subvolume only when / is one, as on the nuc
    # (@root). This VM's root isn't, so tmpfiles fell back to a plain
    # directory, silently, the case the check exists for.
    nuc.fail("btrfs subvolume show /srv/microvms")
    nuc.fail("systemctl start microvm-state.service")
    nuc.succeed("journalctl -u microvm-state.service | grep -F 'is not a btrfs subvolume'")
    assert nuc.succeed("systemctl show -P OnFailure microvm-state.service").strip()

with subtest("a NOCOW subvolume, as tmpfiles makes it on the nuc, passes, and a VM needs it"):
    nuc.succeed(
        "rmdir /srv/microvms",
        "btrfs subvolume create /srv/microvms",
        "chattr +C /srv/microvms",
    )
    nuc.succeed("systemctl restart microvm-state.service")
    requires = nuc.succeed("systemctl show -P Requires microvm@probe.service")
    assert "microvm-state.service" in requires, requires

with subtest("negative control: a subvolume with copy-on-write fails"):
    nuc.succeed(
        "btrfs subvolume delete /srv/microvms",
        "btrfs subvolume create /srv/microvms",
    )
    nuc.fail("systemctl restart microvm-state.service")
    nuc.succeed("journalctl -u microvm-state.service | grep -F 'is not NOCOW'")
