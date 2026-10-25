# Test script for tests/game-access.nix. `nuc`, `friend`, `member` and
# `headscale` are the test driver's machines; LAN_IP and GAME_PORT are defined
# by the Nix file in front of this script.
#
# LAN: local area network. TCP: Transmission Control Protocol. HTTP:
# Hypertext Transfer Protocol.
import json
import re


def open_ports(out):
    return sorted(int(p) for p in re.findall(r"^(\d+)/tcp\s+open\b", out, re.M))


def game(ip):
    # busybox's httpd answers 404 for /, which is enough: something answered.
    return f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 http://{ip}:{GAME_PORT}/"


start_all()
headscale.wait_for_unit("headscale.service")
headscale.wait_for_open_port(443)
# As in tests/tailscale.py: the command's socket can come up after nginx.
headscale.wait_until_succeeds("headscale users list", timeout=120)
headscale.succeed("headscale users create member")
headscale.succeed("headscale users create friend")
USERS = {
    u["name"]: u["id"] for u in json.loads(headscale.succeed("headscale users list -o json"))
}


def set_policy(acls):
    # Headscale's form of the tailnet's access policy. `member@` stands in for
    # `autogroup:member`, Alex's own devices; `friend@` for `autogroup:shared`,
    # everyone the nuc is shared with (docs/runbooks/tailscale.md).
    policy = json.dumps({"tagOwners": {"tag:server": ["member@"]}, "acls": acls})
    headscale.succeed(f"printf %s '{policy}' > /tmp/policy.json")
    headscale.succeed("headscale policy set -f /tmp/policy.json")


MEMBER_RULE = {
    "action": "accept",
    "src": ["member@"],
    "proto": "tcp",
    "dst": ["tag:server:22", f"tag:server:{GAME_PORT}"],
}
FRIEND_RULE = {
    "action": "accept",
    "src": ["friend@"],
    "proto": "tcp",
    "dst": [f"tag:server:{GAME_PORT}"],
}
set_policy([MEMBER_RULE, FRIEND_RULE])


def new_key(user, tags=""):
    return headscale.succeed(
        f"headscale preauthkeys -u {USERS[user]} create {tags}"
    ).strip()


with subtest("the nuc, a friend and a member join the tailnet"):
    nuc.wait_for_unit("tailscaled.service")
    nuc.succeed("install -m 600 /dev/null /run/ts-authkey")
    nuc.succeed(f"printf %s '{new_key('member', '--tags tag:server')}' > /run/ts-authkey")
    nuc.succeed("systemctl start tailscaled-autoconnect.service")
    NUC_TS_IP = nuc.succeed("tailscale ip -4").strip()
    print(f"nuc's tailnet address: {NUC_TS_IP}")
    assert NUC_TS_IP.startswith("100."), NUC_TS_IP
    for machine, user in ((friend, "friend"), (member, "member")):
        machine.wait_for_unit("tailscaled.service")
        machine.succeed(
            f"tailscale up --login-server https://headscale --auth-key '{new_key(user)}'"
        )

with subtest("the game stack is up and listening on every IPv4 address"):
    nuc.wait_for_unit("stack-game.service")
    nuc.wait_until_succeeds(f"ss -Hltn 'sport = :{GAME_PORT}' | grep -q '0.0.0.0:{GAME_PORT}'")
    # Control: the server answers on the nuc itself.
    nuc.wait_until_succeeds(f"{game('127.0.0.1')} | grep -q 404", timeout=60)

with subtest("a friend reaches the game port over the tailnet, by name"):
    friend.wait_until_succeeds("getent hosts nuc.tailnet", timeout=60)
    out = friend.wait_until_succeeds(f"{game('nuc.tailnet')} | grep 404", timeout=60)
    print(f"friend -> nuc.tailnet:{GAME_PORT}: {out}")

with subtest("the connection came in on tailscale0 and stack-ports admitted it"):
    # Docker redirects the published port, so the connection takes the
    # forward path, where stack-ports' accept rule for tailscale0 counts it.
    rules = nuc.succeed("nft list chain inet stack-ports forward")
    print(rules)
    accept = re.search(
        rf'iifname "tailscale0" meta l4proto tcp ct original proto-dst {GAME_PORT} counter packets (\d+)',
        rules,
    )
    assert accept and int(accept.group(1)) > 0, rules
    accepted = nuc.succeed(f"journalctl -k --grep 'stack-port accept {GAME_PORT}/tcp' -o cat")
    print(accepted)
    assert "IN=tailscale0" in accepted, accepted

with subtest("a friend reaches nothing else the policy controls"):
    # 22 is open in the nuc's firewall on tailscale0, so a filtered 22 here is
    # the policy, not the firewall. The peer API is left out: the policy
    # cannot close it (tests/tailscale.py).
    out = friend.succeed(f"nmap -Pn -p 22,80,443,{GAME_PORT} {NUC_TS_IP}")
    print(out)
    assert open_ports(out) == [GAME_PORT], open_ports(out)

with subtest("a member reaches SSH and the game over the tailnet"):
    out = member.succeed(f"nmap -Pn -p 22,{GAME_PORT} {NUC_TS_IP}")
    print(out)
    assert open_ports(out) == [22, GAME_PORT], open_ports(out)
    member.succeed(f"{game(NUC_TS_IP)} | grep -q 404")

with subtest("nobody reaches the game port from the LAN"):
    # The member is on the LAN too: the same device, the same port, refused
    # at the nuc's LAN address. Control: the LAN path itself works, since the
    # nuc answers a ping there.
    member.succeed(f"ping -c 1 -W 2 {LAN_IP}")
    member.fail(f"{game(LAN_IP)} | grep -q 404")
    # Logged after Docker's redirect, so DPT is the container's port, 8080
    # (docs/runbooks/stacks.md).
    nuc.wait_until_succeeds(
        "journalctl -k --grep 'stack-port drop' -o cat | grep -q 'IN=lan0 .*DPT=8080 '",
        timeout=30,
    )

with subtest("negative control: without its rule, the friend is shut out"):
    set_policy([MEMBER_RULE])
    friend.wait_until_fails(f"{game(NUC_TS_IP)} | grep -q 404", timeout=60)
    # The member's rule still works, so the failure is the friend's rule.
    member.succeed(f"{game(NUC_TS_IP)} | grep -q 404")
    set_policy([MEMBER_RULE, FRIEND_RULE])
    friend.wait_until_succeeds(f"{game(NUC_TS_IP)} | grep -q 404", timeout=60)

with subtest("negative control: the port on lan0 opens the LAN and shuts the tailnet"):
    nuc.succeed("/run/current-system/specialisation/onLan/bin/switch-to-configuration test")
    nuc.wait_until_succeeds(f"nft list chain inet stack-ports forward | grep -q 'iifname \"lan0\".*proto-dst {GAME_PORT}'")
    member.wait_until_succeeds(f"{game(LAN_IP)} | grep -q 404", timeout=60)
    friend.fail(f"{game(NUC_TS_IP)} | grep -q 404")
