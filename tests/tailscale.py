# Test script for tests/tailscale.nix. `nuc`, `client` and `headscale` are the
# test driver's machines; LAN_IP and SNAKEOIL_KEY are defined by the Nix file in
# front of this script.
#
# LAN: local area network. DNS: Domain Name System. TCP: Transmission Control
# Protocol. API: application programming interface.
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


def set_policy(acls):
    # Headscale's form of the tailnet's access policy (HuJSON, a JSON with
    # comments; plain JSON here). `test@` is the user every device belongs to,
    # as Alex's devices belong to him.
    policy = json.dumps({"tagOwners": {"tag:server": ["test@"]}, "acls": acls})
    headscale.succeed(f"printf %s '{policy}' > /tmp/policy.json")
    headscale.succeed("headscale policy set -f /tmp/policy.json")


# Tailscale's default rule, every device to every other, plus the tag's owner:
# the tailnet after the tag is created, before the runbook's rules replace
# the default.
set_policy([{"action": "accept", "src": ["*"], "dst": ["*:*"]}])


def new_key(tags=""):
    # Single use, like the real tagged key: not --reusable.
    return headscale.succeed(f"headscale preauthkeys -u 1 create {tags}").strip()


with subtest("the nuc joins the tailnet from its auth key file"):
    nuc.wait_for_unit("tailscaled.service")
    nuc.succeed("install -m 600 /dev/null /run/ts-authkey")
    nuc.succeed(f"printf %s '{new_key('--tags tag:server')}' > /run/ts-authkey")
    # The unit started at boot, before the key existed, and is still waiting
    # to log in; on the real machine sops writes the file before it starts.
    nuc.succeed("systemctl restart tailscaled-autoconnect.service")
    NUC_TS_IP = nuc.succeed("tailscale ip -4").strip()
    print(f"nuc's tailnet address: {NUC_TS_IP}")
    assert NUC_TS_IP.startswith("100."), NUC_TS_IP
    tags = json.loads(nuc.succeed("tailscale status --json"))["Self"].get("Tags")
    print(f"nuc's tags: {tags}")
    assert tags == ["tag:server"], tags

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
    # Control for CorpDNS above: without the flag, Tailscale takes over DNS.
    client_prefs = json.loads(client.succeed("tailscale debug prefs"))
    assert client_prefs["CorpDNS"] is True, client_prefs["CorpDNS"]

with subtest("both auth keys are single-use, and spent"):
    keys = json.loads(headscale.succeed("headscale preauthkeys list -o json"))
    print(keys)
    assert len(keys) == 2, keys
    # The JSON leaves out fields that are false.
    assert not any(k.get("reusable", False) for k in keys), keys
    assert all(k.get("used", False) for k in keys), keys

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
    # the nuc's firewall never sees those packets and cannot close it (nor can
    # the access policy, below). Found by this scan.
    listeners = nuc.succeed(f"ss -ltnpH src {NUC_TS_IP}")
    print(listeners)
    peerapi = [
        int(line.split()[3].rsplit(":", 1)[1])
        for line in listeners.splitlines()
        if "tailscaled" in line
    ]
    assert len(peerapi) == 1, listeners
    PEERAPI = peerapi[0]
    # Alone it takes about 2.5 minutes; the timeout fails a stalled scan
    # (no ports reported) long before the test's one-hour limit.
    out = client.succeed(
        f"nmap -Pn -p- -T4 --max-retries 1 --host-timeout 10m {NUC_TS_IP}"
    )
    print(out)
    assert open_ports(out) == sorted([22, PEERAPI]), open_ports(out)

with subtest("negative control: the scan sees a port opened on tailscale0"):
    nuc.succeed(
        'nft add rule inet nixos-fw input-allow iifname "tailscale0" tcp dport 8080 accept'
    )
    out = client.succeed(f"nmap -Pn -p 22,8080 {NUC_TS_IP}")
    print(out)
    assert open_ports(out) == [22, 8080], open_ports(out)

with subtest("the access policy closes all but SSH and the peer API"):
    CLIENT_TS_IP = client.succeed("tailscale ip -4").strip()
    # Controls: with no policy, the nuc reaches the client, and the client
    # reaches 8080 (opened above) and the peer API.
    nuc.succeed(f"ping -c 1 -W 2 {CLIENT_TS_IP}")
    out = client.succeed(f"nmap -Pn -p 22,8080,{PEERAPI} {NUC_TS_IP}")
    assert open_ports(out) == sorted([22, 8080, PEERAPI]), open_ports(out)
    # The runbook's rule for the nuc: your devices reach it on TCP 22 only,
    # and nothing names tag:server as a source. The real tailnet's policy is
    # checked at #14.
    set_policy(
        [
            {
                "action": "accept",
                "src": ["test@"],
                "proto": "tcp",
                "dst": ["tag:server:22"],
            }
        ]
    )
    nuc.wait_until_fails(f"ping -c 1 -W 2 {CLIENT_TS_IP}", timeout=60)
    out = client.succeed(f"nmap -Pn -p 22,8080,{PEERAPI} {NUC_TS_IP}")
    print(out)
    # 8080 is now closed by the policy as well as open in the firewall. The
    # peer API is not: tailscaled lets its connections past the policy on
    # purpose and checks each request itself (net/tstun/wrap.go, "Let peerapi
    # through the filter; its ACLs are handled at L7").
    assert open_ports(out) == sorted([22, PEERAPI]), open_ports(out)
    client.succeed(f"{SSH} ops@nuc.tailnet true")

with subtest("the peer API refuses a device the policy gives no access"):
    out = client.succeed(
        f"curl -s -w ' %{{http_code}}' http://{NUC_TS_IP}:{PEERAPI}/v0/goroutines"
    )
    print(out)
    assert " ".join(out.split()) == "denied; no debug access 403", out

with subtest("SSH is open on lan0 and tailscale0 only"):
    rules = nuc.succeed("nft list chain inet nixos-fw input-allow")
    print(rules)
    # Also catches 22 inside a set, `tcp dport { 22, 80 }`, which NixOS
    # writes when an interface opens more than one port.
    ssh_rules = sorted(
        line.strip()
        for line in rules.split("\n")
        if re.search(r"dport (22\b|\{[^}]*\b22\b)", line)
    )
    assert ssh_rules == [
        'iifname "lan0" tcp dport 22 accept',
        'iifname "tailscale0" tcp dport 22 accept',
    ], ssh_rules
    # The LAN fallback, until #14 removes it: still reachable from the LAN.
    out = headscale.succeed(f"nmap -Pn -p 22 {LAN_IP}")
    print(out)
    assert open_ports(out) == [22], open_ports(out)
