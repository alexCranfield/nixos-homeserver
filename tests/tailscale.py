# Test script for tests/tailscale.nix. `nuc`, `client` and `headscale` are the
# test driver's machines; LAN_IP and SNAKEOIL_KEY are defined by the Nix file in
# front of this script.
#
# LAN: local area network.
import json
import re

# `-n`: never read stdin, or ssh swallows the driver's next line (base-ssh.nix).
SSH = "ssh -n -i key -o StrictHostKeyChecking=no -o BatchMode=yes"


def open_ports(out):
    return sorted(int(p) for p in re.findall(r"^(\d+)/tcp\s+open\b", out, re.M))


start_all()
headscale.wait_for_unit("headscale.service")
headscale.wait_for_open_port(443)
headscale.succeed("headscale users create test")


def new_key():
    # Single use, like the real tagged key: not --reusable.
    return headscale.succeed("headscale preauthkeys -u 1 create").strip()


with subtest("the nuc joins the tailnet from its auth key file"):
    nuc.wait_for_unit("tailscaled.service")
    nuc.succeed("install -m 600 /dev/null /run/ts-authkey")
    nuc.succeed(f"printf %s '{new_key()}' > /run/ts-authkey")
    # The unit ran at boot, before the key existed, and failed; on the real
    # machine sops writes the file before it starts.
    nuc.succeed("systemctl restart tailscaled-autoconnect.service")
    NUC_TS_IP = nuc.succeed("tailscale ip -4").strip()
    print(f"nuc's tailnet address: {NUC_TS_IP}")
    assert NUC_TS_IP.startswith("100."), NUC_TS_IP

with subtest("the nuc keeps its own DNS and does not run Tailscale SSH"):
    prefs = json.loads(nuc.succeed("tailscale debug prefs"))
    print(f"CorpDNS: {prefs['CorpDNS']}, RunSSH: {prefs['RunSSH']}")
    assert prefs["CorpDNS"] is False, prefs["CorpDNS"]
    # Tailscale SSH would answer port 22 inside tailscaled, like the peer API
    # below: around both sshd's key-only rules and the firewall.
    assert prefs["RunSSH"] is False, prefs["RunSSH"]

with subtest("the client, on another network, cannot reach the nuc's LAN address"):
    client.wait_for_unit("tailscaled.service")
    # Control: the address answers from the LAN, so the failure below is the
    # missing route, not a broken ping.
    headscale.succeed(f"ping -c 1 -W 2 {LAN_IP}")
    client.fail(f"ping -c 1 -W 2 {LAN_IP}")
    client.succeed(
        f"tailscale up --login-server https://headscale --auth-key '{new_key()}'"
    )
    client.succeed(f"install -m 600 {SNAKEOIL_KEY} key")

with subtest("ops logs in over the tailnet by the nuc's MagicDNS name"):
    client.wait_until_succeeds("getent hosts nuc.tailnet", timeout=60)
    client.wait_until_succeeds(f"{SSH} ops@nuc.tailnet true", timeout=60)
    # SSH_CONNECTION is "<client ip> <port> <server ip> <port>": the nuc saw
    # the login arrive on its tailnet address.
    conn = client.succeed(f"{SSH} ops@nuc.tailnet 'echo $SSH_CONNECTION'").split()
    print(f"SSH_CONNECTION: {conn}")
    assert conn[2] == NUC_TS_IP, conn

with subtest("a full TCP scan over the tailnet finds SSH and Tailscale's peer API"):
    nuc.wait_for_open_port(8080)
    # tailscaled's peer API (Taildrop and similar), on a random port on the
    # tailnet address. tailscaled answers it inside its own network stack, so
    # the nuc's firewall never sees those packets and cannot close it; only
    # the tailnet's access rules limit who reaches it. Found by this scan.
    listeners = nuc.succeed(f"ss -ltnpH src {NUC_TS_IP}")
    print(listeners)
    peerapi = [
        int(line.split()[3].rsplit(":", 1)[1])
        for line in listeners.splitlines()
        if "tailscaled" in line
    ]
    assert len(peerapi) == 1, listeners
    out = client.succeed(f"nmap -Pn -p- -T4 --max-retries 1 {NUC_TS_IP}")
    print(out)
    assert open_ports(out) == sorted([22, peerapi[0]]), open_ports(out)

with subtest("negative control: the scan sees a port opened on tailscale0"):
    nuc.succeed(
        'nft add rule inet nixos-fw input-allow iifname "tailscale0" tcp dport 8080 accept'
    )
    out = client.succeed(f"nmap -Pn -p 22,8080 {NUC_TS_IP}")
    print(out)
    assert open_ports(out) == [22, 8080], open_ports(out)

with subtest("SSH is open on lan0 and tailscale0 only"):
    rules = nuc.succeed("nft list chain inet nixos-fw input-allow")
    print(rules)
    ssh_rules = sorted(
        line.strip() for line in rules.split("\n") if "tcp dport 22 " in line
    )
    assert ssh_rules == [
        'iifname "lan0" tcp dport 22 accept',
        'iifname "tailscale0" tcp dport 22 accept',
    ], ssh_rules
    # The LAN fallback, until #14 removes it: still reachable from the LAN.
    out = headscale.succeed(f"nmap -Pn -p 22 {LAN_IP}")
    print(out)
    assert open_ports(out) == [22], open_ports(out)
