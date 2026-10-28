# Test script for tests/tailscale.nix. `nuc`, `client` and `headscale` are the
# test driver's machines; LAN_IP, SNAKEOIL_KEY and GRAFANA_PASSWORD are defined
# by the Nix file in front of this script.
#
# LAN: local area network. DNS: Domain Name System. TCP: Transmission Control
# Protocol. API: application programming interface. CI: continuous integration.
import json
import re

# `-n`: never read stdin, or ssh swallows the driver's next line (base-ssh.nix).
SSH = "ssh -n -i key -o StrictHostKeyChecking=no -o BatchMode=yes"


# A peer API request that needs debug access. HTTP: Hypertext Transfer
# Protocol.
PEERAPI_DEBUG = "curl -s -w ' %{{http_code}}' http://{ip}:{port}/v0/goroutines"


def open_ports(out):
    return sorted(int(p) for p in re.findall(r"^(\d+)/tcp\s+open\b", out, re.M))


start_all()
headscale.wait_for_unit("headscale.service")
headscale.wait_for_open_port(443)
# Port 443 is nginx; the headscale command talks to the daemon over its own
# socket, which can come up later. On CI's slower runners it had not, and the
# command gave up (#103). Wait until the command works.
headscale.wait_until_succeeds("headscale users list", timeout=120)
headscale.succeed("headscale users create test")


def set_policy(acls):
    # Headscale's form of the tailnet's access policy (HuJSON, JSON (JavaScript
    # Object Notation) with comments; plain JSON here). `test@` is the user every device belongs to,
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
    # Started only now that the key exists, as on the real machine, where sops
    # writes the file before the unit starts (tests/tailscale.nix, #103).
    nuc.succeed("systemctl start tailscaled-autoconnect.service")
    NUC_TS_IP = nuc.succeed("tailscale ip -4").strip()
    print(f"nuc's tailnet address: {NUC_TS_IP}")
    assert NUC_TS_IP.startswith("100."), NUC_TS_IP
    tags = json.loads(nuc.succeed("tailscale status --json"))["Self"].get("Tags")
    print(f"nuc's tags: {tags}")
    assert tags == ["tag:server"], tags

with subtest("the nuc keeps its own DNS, runs no Tailscale SSH and refuses Taildrop"):
    prefs = json.loads(nuc.succeed("tailscale debug prefs"))
    print(f"CorpDNS: {prefs['CorpDNS']}, RunSSH: {prefs['RunSSH']}")
    assert prefs["CorpDNS"] is False, prefs["CorpDNS"]
    # Tailscale SSH would answer port 22 inside tailscaled, like the peer API
    # below: around both sshd's key-only rules and the firewall.
    assert prefs["RunSSH"] is False, prefs["RunSSH"]
    # Taildrop refuses incoming files (disableTaildrop). Read from the running
    # daemon's environment, not the unit file, so a restart that dropped it
    # would show.
    pid = nuc.succeed("systemctl show -p MainPID --value tailscaled").strip()
    env = nuc.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
    assert "TS_DISABLE_TAILDROP=true" in env.split("\n"), env

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

with subtest("a full TCP scan over the tailnet finds SSH, the peer API and Serve"):
    nuc.wait_for_open_port(8080)
    # Grafana, published on the tailnet by Tailscale Serve (#25). Like the peer
    # API, Serve answers inside tailscaled, so the firewall never sees it;
    # unlike the peer API, the access policy does limit it (below).
    nuc.wait_for_unit("tailscale-serve-grafana.service")
    nuc.wait_for_open_port(3000)
    # tailscaled's peer API (Taildrop and similar), on a random port on the
    # tailnet address. tailscaled answers it inside its own network stack, so
    # the nuc's firewall never sees those packets and cannot close it (nor can
    # the access policy, below). Found by this scan.
    listeners = nuc.succeed(f"ss -ltnpH src {NUC_TS_IP}")
    print(listeners)
    tailscaled_ports = [
        int(line.split()[3].rsplit(":", 1)[1])
        for line in listeners.splitlines()
        if "tailscaled" in line
    ]
    # Serve's port shows here too: tailscaled also listens on the address
    # itself for the nuc's own connections to it.
    assert 3000 in tailscaled_ports, listeners
    peerapi = [p for p in tailscaled_ports if p != 3000]
    assert len(peerapi) == 1, listeners
    PEERAPI = peerapi[0]
    # Alone a scan takes about 2.5 minutes. On CI runners a dropped probe
    # once missed the peer API port (#109's first run), so the scan is
    # repeated, up to three times, until one scan finds exactly SSH, the peer
    # API and Serve. Any other port, in any scan, fails the test at once. Three
    # stalled scans (10 minutes each, no ports reported) still fail well
    # within the test's one-hour limit.
    expected = {22, PEERAPI, 3000}
    for attempt in range(1, 4):
        out = client.succeed(
            f"nmap -Pn -p- -T4 --max-retries 1 --host-timeout 10m {NUC_TS_IP}"
        )
        print(out)
        found = set(open_ports(out))
        assert found <= expected, f"unexpected open ports: {sorted(found - expected)}"
        if found == expected:
            break
        print(f"scan {attempt} found {sorted(found)}, not all known ports")
    assert found == expected, sorted(found)

with subtest("Grafana answers over the tailnet through Serve"):
    out = client.succeed("curl -fsS http://nuc.tailnet:3000/api/health")
    print(out)
    assert json.loads(out)["database"] == "ok", out
    # A browser's login: Grafana checks the Origin against the Host it was
    # reached by, here the tailnet name through Serve's proxy.
    login = json.dumps({"user": "admin", "password": GRAFANA_PASSWORD})
    status = client.succeed(
        "curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' "
        f"-H 'Origin: http://nuc.tailnet:3000' -d '{login}' http://nuc.tailnet:3000/login"
    )
    assert status == "200", status
    # Control: a wrong password through the same path is refused.
    bad = json.dumps({"user": "admin", "password": "wrong"})
    status = client.succeed(
        "curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' "
        f"-H 'Origin: http://nuc.tailnet:3000' -d '{bad}' http://nuc.tailnet:3000/login"
    )
    assert status == "401", status

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
    # reaches 8080 (opened above), Serve and the peer API.
    nuc.succeed(f"ping -c 1 -W 2 {CLIENT_TS_IP}")
    out = client.succeed(f"nmap -Pn -p 22,3000,8080,{PEERAPI} {NUC_TS_IP}")
    assert open_ports(out) == sorted([22, 3000, 8080, PEERAPI]), open_ports(out)
    PEERAPI_BEFORE_POLICY = " ".join(
        client.succeed(PEERAPI_DEBUG.format(ip=NUC_TS_IP, port=PEERAPI)).split()
    )
    print(f"peer API debug request, before the policy: {PEERAPI_BEFORE_POLICY}")
    # The runbook's rule for the nuc: your devices reach it on TCP 22 only,
    # and nothing names tag:server as a source. Its other rule, your devices
    # to each other, is left out: there is only one such device here, and it
    # never applies to the tagged nuc. The real tailnet's policy is checked
    # at #14.
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
    # The ping is dropped by the client's copy of the policy; 8080 by the
    # nuc's, which may arrive a moment later, so wait for that too.
    nuc.wait_until_fails(f"ping -c 1 -W 2 {CLIENT_TS_IP}", timeout=60)
    client.wait_until_succeeds(
        f"nmap -Pn -p 8080 {NUC_TS_IP} | grep -q '^8080/tcp *filtered'", timeout=60
    )
    out = client.succeed(f"nmap -Pn -p 22,3000,8080,{PEERAPI} {NUC_TS_IP}")
    print(out)
    # Serve's 3000 is closed by the policy: share recipients, whom the real
    # policy gives only the game port, never reach Grafana. 8080 is now closed
    # by the policy as well as open in the firewall. The peer API is not:
    # tailscaled lets its connections past the policy on purpose and checks
    # each request itself (net/tstun/wrap.go, "Let peerapi through the
    # filter; its ACLs are handled at L7").
    assert open_ports(out) == sorted([22, PEERAPI]), open_ports(out)
    client.succeed(f"{SSH} ops@nuc.tailnet true")

with subtest("the policy opens Serve when it grants the port"):
    # The real policy's rule for Alex's devices also grants tcp:3000
    # (docs/runbooks/tailscale.md).
    set_policy(
        [
            {
                "action": "accept",
                "src": ["test@"],
                "proto": "tcp",
                "dst": ["tag:server:22,3000"],
            }
        ]
    )
    client.wait_until_succeeds(
        f"nmap -Pn -p 3000 {NUC_TS_IP} | grep -q '^3000/tcp *open'", timeout=60
    )
    client.succeed("curl -fsS -o /dev/null http://nuc.tailnet:3000/api/health")
    # Back to SSH only, as the subtests below expect.
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
    client.wait_until_succeeds(
        f"nmap -Pn -p 3000 {NUC_TS_IP} | grep -q '^3000/tcp *filtered'", timeout=60
    )

with subtest("past the policy, the peer API still checks each request"):
    # An HTTP request gets through to tailscaled's own access check, which
    # refuses it. The check is not the policy: debug is off on the nuc (its
    # control server never grants it), so the answer was the same before the
    # policy, as the previous subtest recorded.
    out = client.succeed(PEERAPI_DEBUG.format(ip=NUC_TS_IP, port=PEERAPI))
    print(out)
    assert " ".join(out.split()) == "denied; no debug access 403", out
    assert " ".join(out.split()) == PEERAPI_BEFORE_POLICY, PEERAPI_BEFORE_POLICY

with subtest("SSH is open on tailscale0 only"):
    rules = nuc.succeed("nft list chain inet nixos-fw input-allow")
    print(rules)
    # Also catches 22 inside a set, `tcp dport { 22, 80 }`, which NixOS
    # writes when an interface opens more than one port.
    ssh_rules = sorted(
        line.strip()
        for line in rules.split("\n")
        if re.search(r"dport (22\b|\{[^}]*\b22\b)", line)
    )
    assert ssh_rules == ['iifname "tailscale0" tcp dport 22 accept'], ssh_rules
    # No LAN fallback since #14: sshd listens, but the LAN cannot reach it.
    out = headscale.succeed(f"nmap -Pn -p 22 {LAN_IP}")
    print(out)
    assert re.search(r"^22/tcp\s+filtered\b", out, re.M), out

with subtest("stopping the Serve unit removes the port"):
    # Serve's configuration lives in tailscaled's state, so a unit that only
    # set it would leave it behind when removed from the configuration.
    # Stopping the unit takes it back. Checked from the client, so through
    # Serve: the nuc's own connections to its tailnet address never reach
    # tailscaled. The policy grants 3000 again for this.
    set_policy(
        [
            {
                "action": "accept",
                "src": ["test@"],
                "proto": "tcp",
                "dst": ["tag:server:22,3000"],
            }
        ]
    )
    url = "http://nuc.tailnet:3000/api/health"
    client.wait_until_succeeds(f"curl -fsS -m 5 -o /dev/null {url}", timeout=60)
    assert ":3000" in nuc.succeed("tailscale serve status")
    nuc.succeed("systemctl stop tailscale-serve-grafana.service")
    status = nuc.succeed("tailscale serve status 2>&1 || true")
    print(status)
    assert ":3000" not in status, status
    client.fail(f"curl -fsS -m 5 -o /dev/null {url}")
    # Control: started again, it answers again.
    nuc.succeed("systemctl start tailscale-serve-grafana.service")
    client.wait_until_succeeds(f"curl -fsS -m 5 -o /dev/null {url}", timeout=60)
