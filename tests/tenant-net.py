# Ticket 6.7 (#197); see tests/tenant-net.nix for the machines.
import json
import re

STAND_INS = {
    # namespace: (VM name, address)
    "tdev": ("tenant-dev", "10.88.0.2"),
    "trun": ("tenant-run", "10.88.0.3"),
}
TENANT_DNS = "10.88.0.1"


def http(url, ns=None):
    """A curl command for url, from inside a stand-in's namespace if given.

    Any HTTP answer counts as reached, a 404 included: busybox's httpd has no
    index page to serve. Blocked means no answer at all.
    """
    cmd = f"curl -sS --max-time 5 -o /dev/null {url}"
    return f"ip netns exec {ns} {cmd}" if ns else cmd


def ping(address, ns=None):
    cmd = f"ping -4 -c 1 -W 2 {address}"
    return f"ip netns exec {ns} {cmd}" if ns else cmd


def dig(server, query, ns=None):
    """A dig command; dig exits non-zero when no server answers."""
    cmd = f"dig +short +time=3 +tries=1 @{server} {query}"
    return f"ip netns exec {ns} {cmd}" if ns else cmd


def drops(chain):
    """Packets the tenant table has dropped in chain, from its named counter."""
    out = json.loads(nuc.succeed(f"nft -j list counter inet tenant-isolation {chain}-drops"))
    return next(o["counter"]["packets"] for o in out["nftables"] if "counter" in o)


def blocked(command, chain):
    """command, run from a stand-in, fails, and the tenant table dropped it."""
    before = drops(chain)
    nuc.fail(command)
    after = drops(chain)
    assert after > before, (
        f"`{command}` failed, but the table's {chain} counter stayed at "
        f"{before}: something else blocked it"
    )


start_all()
for machine in (router, lan, internet):
    machine.wait_for_unit("web.service")
router.wait_for_unit("dnsmasq.service")
nuc.wait_for_unit("multi-user.target")
nuc.wait_for_unit("blocky.service")
nuc.wait_for_unit("blocky-tenant.service")
# It waited for the LAN Blocky's log table and found it, rather than giving
# up after a minute and starting regardless.
nuc.fail("journalctl -u blocky-tenant.service --no-pager | grep -F 'still missing'")
nuc.wait_for_unit("tenant-router-wan.service")
nuc.wait_for_unit("stack-probe.service")
nuc.wait_for_open_port(OPEN_PORT)
nuc.wait_until_succeeds(http(f"http://{NUC_IP}:{PUBLISHED_PORT}/"))
# Unbound forwards to the router here. If it asked before the router's DNS
# was up, it holds the router as unreachable for about 15 minutes; restart
# it, as on the real nuc after an outage, now that dnsmasq is up.
nuc.succeed("systemctl restart unbound.service")
nuc.wait_until_succeeds(f"{dig(TENANT_DNS, 'ok.test')} | grep -qx 198.51.100.7", timeout=60)

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

with subtest("IPv6 a guest sends anyway gets no answer and goes nowhere"):
    # The tap has no IPv6 address or route, so the host can't answer a
    # guest's IPv6, and the reverse-path filter drops it in prerouting, before
    # this table's IPv6 rules, which stay as a further layer. The check is
    # the outcome: the only answer to a ping to all nodes is the stand-in's
    # own (multicast loops back), and the host forwards no IPv6 at all.
    nuc.wait_until_succeeds("ip -n tdev -6 addr show dev eth0 | grep -q 'scope link'")
    own = nuc.succeed(
        "ip -n tdev -6 -o addr show dev eth0 scope link | awk '{print $4}' | cut -d/ -f1"
    ).strip()
    assert own, "the stand-in has no link-local address"
    out = nuc.succeed("ip netns exec tdev ping -6 -c 3 -W 1 ff02::1%eth0 || true")
    responders = {r.split("%")[0] for r in re.findall(r"bytes from ([0-9a-f:%a-z0-9]+):", out)}
    assert own in responders, f"the ping didn't run: {out}"
    assert responders == {own}, f"answered by {responders - {own}}"
    assert nuc.succeed("sysctl -n net.ipv6.conf.all.forwarding").strip() == "0"

    # From here the stand-ins send IPv4 only, as the VMs will (6.8), so the
    # counters below move only for the probe that is being tested.
    for ns in STAND_INS:
        nuc.succeed(
            f"ip netns exec {ns} sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.eth0.disable_ipv6=1"
        )
    # A web server inside one stand-in, as a VM the other must not reach.
    nuc.succeed(f"ip netns exec trun {BUSYBOX} httpd -p 80 -h /etc")
    nuc.wait_until_succeeds(http("http://10.88.0.3/"))

with subtest("negative controls: every target answers from outside the tenants"):
    lan.succeed(http(f"http://{ROUTER_IP}/"))
    lan.succeed(http(f"http://{NUC_IP}:{OPEN_PORT}/"))
    lan.succeed(http(f"http://{NUC_IP}:{PUBLISHED_PORT}/"))
    nuc.succeed(http(f"http://{LAN_IP}/"))
    nuc.succeed(http(f"http://{SHARED_IP}/"))
    nuc.succeed(http(f"http://{ROUTER_WAN_IP}/"))
    nuc.succeed(http(f"http://{INTERNET_IP}/"))
    nuc.succeed(http("http://10.88.0.3/"))
    nuc.succeed(ping(LAN_IP))
    # The LAN's Blocky answers each kind of LAN name, forwards and reverse,
    # so a tenant that could ask it would learn them.
    assert lan.succeed(dig(NUC_IP, "secret-host.home.arpa")).strip() == "192.168.1.88"
    assert "secret-host" in lan.succeed(dig(NUC_IP, "-x 192.168.1.88"))
    assert lan.succeed(dig(NUC_IP, "probe.home.arpa")).strip() == "192.0.2.7"
    assert lan.succeed(dig(NUC_IP, "lan.home.arpa")).strip() == LAN_IP
    assert "lan.home.arpa" in lan.succeed(dig(NUC_IP, f"-x {LAN_IP}"))

for ns in STAND_INS:
    with subtest(f"{ns} reaches the internet and its own Blocky"):
        # `internet` routes only 192.168.1.0/24 back, so this also shows the
        # nuc masquerades the tenant network as its own address.
        nuc.succeed(http(f"http://{INTERNET_IP}/", ns))
        nuc.succeed(ping(INTERNET_IP, ns))
        for flags in ("", "+tcp"):
            nuc.wait_until_succeeds(
                f"{dig(TENANT_DNS, f'{flags} ok.test', ns)} | grep -qx 198.51.100.7", timeout=30
            )
        # Filtered, like the LAN's, once its lists have loaded.
        nuc.wait_until_succeeds(f"{dig(TENANT_DNS, 'ad.test', ns)} | grep -qx 0.0.0.0", timeout=60)

    with subtest(f"{ns} learns no LAN name from its Blocky"):
        # NXDOMAIN, not just no answer: a failing Blocky (SERVFAIL) would
        # also give none.
        for query, secret in (
            ("secret-host.home.arpa", "192.168.1.88"),
            ("probe.home.arpa", "192.0.2.7"),
            ("lan.home.arpa", LAN_IP),
            ("-x 192.168.1.88", "secret-host"),
            (f"-x {LAN_IP}", "lan.home.arpa"),
        ):
            out = nuc.succeed(
                f"ip netns exec {ns} dig +time=3 +tries=1 @{TENANT_DNS} {query}"
            )
            assert "status: NXDOMAIN" in out and "ANSWER: 0," in out, f"{query} from {ns}: {out}"
            assert secret not in out, f"{query} from {ns} gave {secret}: {out}"

    with subtest(f"{ns} reaches nothing else"):
        blocked(http(f"http://{LAN_IP}/", ns), "forward")
        blocked(ping(LAN_IP, ns), "forward")
        blocked(http(f"http://{ROUTER_IP}/", ns), "forward")
        blocked(http(f"http://{ROUTER_WAN_IP}/", ns), "forward")
        blocked(http(f"http://{SHARED_IP}/", ns), "forward")
        # Docker has rewritten the destination to the container's 172.x
        # address by the time the forward rules see it.
        blocked(http(f"http://{NUC_IP}:{PUBLISHED_PORT}/", ns), "forward")
        blocked(http(f"http://{NUC_IP}:{OPEN_PORT}/", ns), "input")
        blocked(http(f"http://{TENANT_DNS}:{OPEN_PORT}/", ns), "input")
        blocked(ping(TENANT_DNS, ns), "input")
        # The LAN's Blocky, which would give away the LAN's names.
        blocked(dig(NUC_IP, "ok.test", ns), "input")

with subtest("one tenant never reaches the other"):
    blocked(http("http://10.88.0.3/", "tdev"), "forward")

with subtest("the tenants' Blocky logs them by their VM names"):
    nuc.wait_until_succeeds(
        "test \"$(sudo -u postgres psql -At blocky -c "
        "\"SELECT count(DISTINCT client_name) FROM log_entries "
        "WHERE question_name LIKE 'ok.test%' "
        "AND client_name IN ('tenant-dev', 'tenant-run')\")\" = 2",
        timeout=90,
    )

with subtest("the router's public address comes back after a reload"):
    nuc.succeed(f"nft get element inet tenant-isolation router-wan '{{ {ROUTER_WAN_IP} }}'")
    # Negative control: without the address in the set, the console is
    # reachable, which is why it is closed.
    nuc.succeed("nft flush set inet tenant-isolation router-wan")
    nuc.succeed(http(f"http://{ROUTER_WAN_IP}/", "tdev"))
    # A reload of the ruleset empties the set; the service puts it back.
    nuc.succeed("systemctl reload nftables.service")
    nuc.wait_until_succeeds(
        f"nft get element inet tenant-isolation router-wan '{{ {ROUTER_WAN_IP} }}'", timeout=30
    )
    blocked(http(f"http://{ROUTER_WAN_IP}/", "tdev"), "forward")
    # A restart of the ruleset empties it too; the service is restarted with
    # it.
    nuc.succeed("systemctl restart nftables.service")
    nuc.wait_until_succeeds(
        f"nft get element inet tenant-isolation router-wan '{{ {ROUTER_WAN_IP} }}'", timeout=30
    )
    blocked(http(f"http://{ROUTER_WAN_IP}/", "tdev"), "forward")

with subtest("negative control: without the table, the same probes get through"):
    # The system to come back to: once switched, /run/current-system is the
    # specialisation.
    base = nuc.succeed("readlink -f /run/current-system").strip()
    nuc.succeed(f"{base}/specialisation/isolationOff/bin/switch-to-configuration test")
    nuc.fail("nft list table inet tenant-isolation")
    nuc.succeed(http(f"http://{LAN_IP}/", "tdev"))
    nuc.succeed(http(f"http://{NUC_IP}:{OPEN_PORT}/", "tdev"))
    nuc.succeed(http(f"http://{TENANT_DNS}:{OPEN_PORT}/", "tdev"))
    nuc.succeed(ping(LAN_IP, "tdev"))
    # Not the other stand-in: NixOS's own forward rules drop that anyway,
    # accepting tenant traffic only on its way out of lan0.
    nuc.succeed(f"{base}/bin/switch-to-configuration test")
    nuc.succeed("nft list table inet tenant-isolation")
    blocked(http(f"http://{LAN_IP}/", "tdev"), "forward")
    # Switching back starts the address service again.
    nuc.wait_until_succeeds(
        f"nft get element inet tenant-isolation router-wan '{{ {ROUTER_WAN_IP} }}'", timeout=30
    )

with subtest("a test node has the tenants' network but declares no VMs"):
    # A VM inside this one would have no KVM (modules/tenants/default.nix).
    out = nuc.succeed("systemctl list-units --all --no-legend 'microvm@*' 'install-microvm-*'")
    assert out.strip() == "", out
    # microvm.nix's template is there; this repository's drop-in, with the
    # VM's memory ceiling, is not.
    unit = nuc.succeed("systemctl cat microvm@tenant-dev.service")
    assert "MemoryMax" not in unit, unit

with subtest("negative control: tmpfiles' plain-directory fallback fails the check"):
    # tmpfiles `v` makes a subvolume only when / is one, as on the nuc
    # (@root). This VM's root isn't, so tmpfiles fell back to a plain
    # directory, silently, the case the check exists for.
    nuc.fail("btrfs subvolume show /srv/microvms")
    nuc.fail("systemctl start microvm-state.service")
    nuc.succeed("journalctl -u microvm-state.service | grep -F 'is not a btrfs subvolume'")
    assert nuc.succeed("systemctl show -P OnFailure microvm-state.service").strip()

with subtest("a NOCOW subvolume, as tmpfiles makes it on the nuc, passes, and a VM needs it"):
    # The host has made each VM's own directory inside it (install-microvm-*),
    # so it isn't empty.
    nuc.succeed(
        "rm -rf /srv/microvms",
        "btrfs subvolume create /srv/microvms",
        "chattr +C /srv/microvms",
    )
    nuc.succeed("systemctl start microvm-state.service")
    nuc.succeed("microvm-state-check")
    requires = nuc.succeed("systemctl show -P Requires microvm@probe.service")
    assert "microvm-state.service" in requires, requires

with subtest("negative control: a subvolume with copy-on-write fails"):
    nuc.succeed(
        "btrfs subvolume delete /srv/microvms",
        "btrfs subvolume create /srv/microvms",
    )
    out = nuc.fail("microvm-state-check 2>&1")
    assert "is not NOCOW" in out, out
