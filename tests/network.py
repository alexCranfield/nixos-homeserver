# Test script for tests/network.nix. `nuc` and `router` are the test driver's
# machines; RESERVED_IP is defined by the Nix file in front of this script.
#
# LAN: local area network. DHCP: Dynamic Host Configuration Protocol.
import re

start_all()
router.wait_for_unit("dnsmasq.service")
# Nothing on the nuc wants network-online.target yet, so systemd would never
# start wait-online. Ask for it: this blocks until lan0 is routable. (The
# held-down port cannot block it: systemd forces RequiredForOnline=no on an
# always-down link, which a run with it set to yes confirmed.)
nuc.wait_for_unit("multi-user.target")
nuc.succeed("systemctl start network-online.target")
nuc.wait_for_unit("systemd-networkd-wait-online.service")


def open_ports(out):
    return sorted(int(p) for p in re.findall(r"^(\d+)/tcp\s+open\b", out, re.M))


with subtest("the server port is named lan0, matched by its MAC address"):
    links = nuc.succeed("ip -br link").split("\n")
    print("\n".join(links))
    names = [line.split()[0] for line in links if line]
    assert "lan0" in names, names
    assert "lo" not in names, names  # temporary: #137 negative control, must fail
    # Renamed, not duplicated: the kernel's name for it is gone.
    assert "eth1" not in names, names

with subtest("lan0 has the reserved address from DHCP"):
    addr = nuc.succeed("ip -4 -br addr show lan0")
    print(addr)
    assert f"{RESERVED_IP}/" in addr, addr

with subtest("the unused port is held down with no address"):
    out = nuc.succeed("ip -br link show eth2")
    print(out)
    assert out.split()[1] == "DOWN", out
    assert "inet " not in nuc.succeed("ip -4 addr show eth2")

with subtest("the router resolves nuc.home.arpa to the reserved address"):
    answer = router.succeed("dig +short @127.0.0.1 nuc.home.arpa").strip()
    print(f"nuc.home.arpa -> {answer}")
    assert answer == RESERVED_IP, answer
    router.succeed("ping -c 1 -W 2 nuc.home.arpa")

with subtest("the firewall hides a listening port"):
    # The listener is really there, seen from the nuc itself.
    nuc.wait_for_open_port(8080)

with subtest("a full TCP scan from the LAN finds nothing open, SSH included"):
    # sshd is listening (control): only the firewall keeps it from the LAN.
    nuc.wait_for_open_port(22)
    # A fixed minimum rate: with every port dropped, nmap otherwise slows itself
    # down and took 21 minutes here. And nmap reports no open port both for a
    # clean result and for a scan it gave up on, so check it covered all 65535.
    out = router.succeed(
        f"nmap -Pn -p- --min-rate 1000 --max-retries 1 {RESERVED_IP}"
    )
    print(out)
    assert "Not shown: 65535 filtered tcp ports" in out, out
    assert open_ports(out) == [], open_ports(out)

with subtest("negative control: the scan does see a port the firewall allows"):
    nuc.succeed("nft add rule inet nixos-fw input-allow tcp dport 8080 accept")
    out = router.succeed(f"nmap -Pn -p 22,8080 {RESERVED_IP}")
    print(out)
    assert open_ports(out) == [8080], open_ports(out)

with subtest("no UDP port is allowed in, beyond the DHCPv6 client"):
    rules = nuc.succeed("nft list chain inet nixos-fw input-allow")
    print(rules)
    # NixOS's own rule, for replies to the DHCPv6 (DHCP for IPv6) client,
    # sent to the link-local address only.
    udp = [line.strip() for line in rules.split("\n") if "udp" in line]
    assert udp == [
        'ip6 daddr fe80::/64 udp dport 546 accept comment "DHCPv6 client"'
    ], udp
    # nixos-firewall-tool's set for ports opened by hand until reboot: empty.
    temp = nuc.succeed("nft list set inet nixos-fw temp-ports")
    print(temp)
    assert "elements" not in temp, temp
