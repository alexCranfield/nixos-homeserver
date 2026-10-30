# Test script for tests/dns.nix. `nuc`, `router` and `client` are the test
# driver's machines; NUC_IP and ROUTER_IP are defined by the Nix file in front
# of this script. CLIENT_IP is the client's address; GRAFANA_PASSWORD is the
# admin password the test gives Grafana. NAS_IP is the NAS stand-in's address.
#
# LAN: local area network. DNS: Domain Name System. NXDOMAIN: the answer "no
# such name". TCP: Transmission Control Protocol.

import json
import re

start_all()
router.wait_for_unit("dnsmasq.service")
nuc.wait_for_unit("blocky.service")
nuc.wait_for_open_port(53, NUC_IP)
# The lists load after Blocky starts answering (fail open). Wait until both
# groups' blocklists have entries, by Blocky's own metrics: its log says
# "group import finished" for the allowlists too. The ads group waits out its
# unreachable list's download attempts first.
for group in ("ads", "threats"):
    nuc.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/metrics"
        f" | grep -E '^blocky_denylist_cache_entries\\{{group=\"{group}\"\\}} [1-9]'",
        timeout=120,
    )
print(nuc.succeed("curl -fsS http://127.0.0.1:4000/metrics | grep _cache_entries"))


def dig(name, server=NUC_IP, qtype="A"):
    return client.succeed(
        f"dig +short +time=2 +tries=1 @{server} {name} {qtype}"
    ).strip()


def wait_for_probe(job, server, value, timeout=180):
    """Wait until Prometheus (on the nuc) holds probe_success == value for the
    job and server, then return. It scrapes every 15 seconds."""
    q = f"probe_success%7Bjob%3D%22{job}%22%2Cserver%3D%22{server}%22%7D"
    nuc.wait_until_succeeds(
        f"curl -fsS 'http://127.0.0.1:9090/api/v1/query?query={q}'"
        f" | grep -F '\"value\":[' | grep -qF '\"{value}\"]'",
        timeout=timeout,
    )


with subtest("resolves a normal name"):
    assert dig("example.test") == "192.0.2.10", dig("example.test")

with subtest("blocks a name on each group, answers 0.0.0.0"):
    assert dig("ad.test") == "0.0.0.0", dig("ad.test")
    assert dig("threat.test") == "0.0.0.0", dig("threat.test")
    # Control: the same names, asked of the router directly, have real
    # answers, so the 0.0.0.0 above is Blocky's.
    assert dig("ad.test", server=ROUTER_IP) == "192.0.2.12"
    assert dig("threat.test", server=ROUTER_IP) == "192.0.2.13"

with subtest("record whether an adblock-syntax line blocks (no assertion)"):
    print(f"adsyntax.test -> {dig('adsyntax.test')!r}")

with subtest("the allowlist wins over a list"):
    assert dig("allowed.test") == "192.0.2.11", dig("allowed.test")

with subtest("a declared record and a private record answer"):
    assert dig("svc.home.arpa") == "192.168.1.77", dig("svc.home.arpa")
    assert dig("secret-host.home.arpa") == "192.168.1.88", dig("secret-host.home.arpa")

with subtest("the private record is not in Blocky's configuration"):
    # Everything Blocky's unit refers to, its configuration included.
    unit = nuc.succeed("readlink -f /etc/systemd/system/blocky.service").strip()
    closure = nuc.succeed(f"nix-store -qR {unit}").split()
    print(f"{len(closure)} store paths in blocky.service's closure")
    assert len(closure) > 1, closure
    # Text files only (-I): a leaked record would be in one, and the binaries
    # are most of the closure. grep exits 1 for no match and 2 for an error,
    # which must not pass.
    status, out = nuc.execute(f"grep -rlFI secret-host {' '.join(closure)}")
    print(f"grep exited {status}: {out!r}")
    assert status == 1, (status, out)
    # Control: the same search finds it through the test's own copy
    # (tests/dns.nix), which the boot-time file rules refer to, so the search
    # above would have found it too.
    rules = nuc.succeed("readlink -f /etc/tmpfiles.d/00-nixos.conf").strip()
    found = nuc.succeed(f"grep -rlFI secret-host $(nix-store -qR {rules})")
    print(found)
    assert "dns-test-private-hosts-fixture" in found, found

with subtest("Firefox's canary gets NXDOMAIN"):
    out = client.succeed(f"dig +time=2 +tries=1 @{NUC_IP} use-application-dns.net")
    print(out)
    assert "status: NXDOMAIN" in out, out
    # Control: the "internet" has an answer for it, which Unbound overrides.
    assert dig("use-application-dns.net", server=ROUTER_IP) == "192.0.2.15"

with subtest("a public name can't answer with a LAN address"):
    # Control: the "internet" does answer with one.
    assert dig("a.rebind.test", server=ROUTER_IP) == "192.168.1.66"
    out = dig("a.rebind.test")
    print(f"a.rebind.test -> {out!r}")
    assert "192.168.1.66" not in out, out

with subtest("negative control: without private-address the LAN address comes back"):
    # Switch to the specialisation without Unbound's private-address, as
    # tests/docker.py does, ask a fresh name (no cache holds it), then switch
    # back.
    nuc.succeed(
        "/run/booted-system/specialisation/unprotected/bin/switch-to-configuration test"
    )
    conf = nuc.succeed("cat /etc/unbound/unbound.conf")
    assert "private-address" not in conf, conf
    nuc.wait_for_open_port(5335, "127.0.0.1")
    out = dig("b.rebind.test")
    print(f"b.rebind.test, unprotected -> {out!r}")
    assert out == "192.168.1.66", out
    nuc.succeed("/run/booted-system/bin/switch-to-configuration test")
    nuc.wait_for_open_port(5335, "127.0.0.1")
    assert "private-address" in nuc.succeed("cat /etc/unbound/unbound.conf")

with subtest("insecureDomains renders Unbound's domain-insecure"):
    conf = nuc.succeed("cat /etc/unbound/unbound.conf")
    lines = [l.strip() for l in conf.splitlines() if "domain-insecure" in l]
    print(lines)
    assert lines == ['domain-insecure: "example.test."'], lines
    # Control: the configuration without it has none.
    other = nuc.succeed(
        "cat /run/booted-system/specialisation/unprotected/etc/unbound/unbound.conf"
    )
    assert "domain-insecure" not in other, other

with subtest("home.arpa and reverse lookups go to the router"):
    assert dig("router.home.arpa") == ROUTER_IP, dig("router.home.arpa")
    ptr = client.succeed(f"dig +short +time=2 +tries=1 @{NUC_IP} -x {NUC_IP}").strip()
    print(f"{NUC_IP} -> {ptr}")
    assert ptr == "nuc.home.arpa.", ptr

with subtest("port 53 is open on the LAN, nothing else is"):
    client.succeed(f"dig +tcp +time=2 +tries=1 @{NUC_IP} example.test")
    # Controls: Blocky's HTTP port and Unbound listen, on the nuc's loopback.
    nuc.wait_for_open_port(4000, "127.0.0.1")
    nuc.wait_for_open_port(5335, "127.0.0.1")
    # 5432: PostgreSQL, for the query log.
    for port in (4000, 5335, 5432):
        client.fail(f"nc -z -w 2 {NUC_IP} {port}")

with subtest("the nuc's own resolver is not Blocky"):
    out = nuc.succeed("resolvectl dns lan0")
    print(out)
    assert NUC_IP not in out, out
    assert ROUTER_IP in out, out

with subtest("queries land in the log, named or by address"):
    dig("example.test")
    # Blocky writes in batches, every 30 seconds by default.
    out = nuc.wait_until_succeeds(
        "sudo -u postgres psql -At blocky -c "
        "\"select client_ip, question_name from log_entries where question_name like 'example.test%'\"",
        timeout=90,
    )
    print(out)
    assert CLIENT_IP in out, out

with subtest("Grafana's role reads and cannot write"):
    nuc.succeed("sudo -u grafana psql -At blocky -c 'select count(*) from log_entries'")
    status, out = nuc.execute("sudo -u grafana psql blocky -c 'delete from log_entries' 2>&1")
    print(out)
    assert status != 0 and "permission denied" in out, (status, out)
    # Control: the same delete as the superuser succeeds, so the refusal above
    # is the role's, not a typo. Nothing matches, so no rows go.
    nuc.succeed(
        "sudo -u postgres psql blocky -c \"delete from log_entries where question_name = 'no-such-name.invalid'\""
    )

with subtest("Grafana's data source reads the log through its socket"):
    nuc.wait_for_unit("grafana.service")
    nuc.wait_for_open_port(3000, "127.0.0.1")
    body = json.dumps({"queries": [{
        "refId": "A", "datasource": {"uid": "dns-querylog"}, "format": "table",
        "rawSql": "select count(*) as n from log_entries",
    }]})
    out = nuc.succeed(
        f"curl -fsS -u admin:{GRAFANA_PASSWORD} -H 'Content-Type: application/json'"
        f" -d '{body}' http://127.0.0.1:3000/api/ds/query"
    )
    print(out)
    assert '"error"' not in out and '"n"' in out, out

with subtest("blocky owns the log's table and dns-watch can only read it"):
    nuc.succeed("sudo -u postgres psql -At blocky -c \"select tableowner from pg_tables where tablename = 'log_entries'\" | grep -qx blocky")
    # dns-watch (the alert queries, Task 5) has no OS user yet, so check the
    # privileges rather than connecting as it.
    nuc.succeed("sudo -u postgres psql -At blocky -c \"select has_table_privilege('dns-watch', 'log_entries', 'select')\" | grep -qx t")
    nuc.succeed("sudo -u postgres psql -At blocky -c \"select has_table_privilege('dns-watch', 'log_entries', 'delete')\" | grep -qx f")

with subtest("retention is 14 days"):
    # The configuration file is named in the unit's command line.
    unit = nuc.succeed("systemctl cat blocky.service")
    config = re.search(r"--config\s+(/nix/store/\S+\.yaml)", unit)
    assert config, unit
    text = nuc.succeed(f"cat {config.group(1)}")
    assert "logRetentionDays: 14" in text, text
    # And Blocky itself read it that way.
    nuc.succeed("journalctl -u blocky.service --no-pager | grep -F 'logRetentionDays: 14'")

with subtest("DNS keeps answering with PostgreSQL stopped"):
    nuc.succeed("systemctl stop postgresql")
    assert dig("example.test") == "192.0.2.10", dig("example.test")
    nuc.succeed("systemctl start postgresql")

with subtest("Blocky starts while PostgreSQL is down, and logs again after"):
    # A PostgreSQL that can't start: stopped, and the start refused, because
    # starting Blocky otherwise starts PostgreSQL with it (through the grants
    # unit).
    nuc.succeed("mkdir -p /run/systemd/system/postgresql.service.d")
    nuc.succeed(
        "printf '[Service]\\nExecStartPre=/run/current-system/sw/bin/false\\n'"
        " > /run/systemd/system/postgresql.service.d/broken.conf"
    )
    nuc.succeed("systemctl daemon-reload && systemctl stop postgresql")
    nuc.succeed("systemctl restart blocky.service")
    nuc.wait_for_open_port(53, NUC_IP)
    assert dig("example.test") == "192.0.2.10", dig("example.test")
    # Blocky 0.29's own fallback to logging on its console.
    nuc.succeed("journalctl -u blocky.service --no-pager | grep -F 'using console as fallback'")
    nuc.succeed("rm /run/systemd/system/postgresql.service.d/broken.conf && systemctl daemon-reload")
    # The refused starts hit systemd's start limit.
    nuc.succeed("systemctl reset-failed postgresql.service && systemctl start postgresql")
    nuc.wait_for_unit("postgresql-setup.service")
    # The timer's job, run directly rather than waiting five minutes.
    nuc.succeed("systemctl start dns-querylog-reattach.service")
    nuc.wait_for_open_port(53, NUC_IP)
    dig("reattached.example.test")
    nuc.wait_until_succeeds(
        "sudo -u postgres psql -At blocky -c "
        "\"select 1 from log_entries where question_name like 'reattached.example.test%'\" | grep -qx 1",
        timeout=90,
    )

with subtest("Blocky comes up when the LAN address arrives late"):
    # As after a power cut, when the router boots slower than the nuc: lan0
    # has no address when Blocky starts, and gets one minutes later.
    router.succeed("systemctl stop dnsmasq.service")
    nuc.succeed("networkctl down lan0")
    nuc.succeed("networkctl up lan0")
    nuc.wait_until_succeeds(f"! ip -4 addr show lan0 | grep -qF 'inet {NUC_IP}/'", timeout=30)
    before = int(nuc.succeed("systemctl show -P NRestarts blocky.service"))
    nuc.succeed("systemctl restart blocky.service")
    # Blocky can't bind the address, exits with an error, and is restarted.
    nuc.wait_until_succeeds(
        f"test $(systemctl show -P NRestarts blocky.service) -gt {before}", timeout=60
    )
    print(nuc.succeed("journalctl -u blocky.service -n 30 --no-pager | grep -iE 'bind|exited|start'"))
    # Longer than five restarts 5 seconds apart, the start limit this used
    # to have.
    nuc.succeed("sleep 35")
    print(nuc.succeed("systemctl show -p ActiveState,Result,NRestarts blocky.service"))
    router.succeed("systemctl start dnsmasq.service")
    nuc.wait_until_succeeds(f"ip -4 addr show lan0 | grep -qF 'inet {NUC_IP}/'", timeout=120)
    # Within the longest gap between retries, 60 seconds, plus a start.
    nuc.wait_for_open_port(53, NUC_IP, timeout=120)
    assert dig("example.test") == "192.0.2.10", dig("example.test")

with subtest("Blocky is up after a reboot"):
    nuc.shutdown()
    nuc.start()
    nuc.wait_for_unit("blocky.service")
    nuc.wait_for_open_port(53, NUC_IP)
    print(nuc.succeed("systemctl show -p NRestarts blocky.service"))
    assert dig("example.test") == "192.0.2.10", dig("example.test")

with subtest("both servers are probed and pass"):
    for job in ("dns_resolve", "dns_blocked"):
        for server in ("nuc", "nas"):
            wait_for_probe(job, server, 1)

with subtest("the NAS's address is not in the system closure"):
    # Everything Prometheus and the exporter run from, their configuration
    # included. The address reaches Prometheus only through the file that
    # tmpfiles writes at boot (as sops does on the real machine).
    for unit in ("prometheus", "prometheus-blackbox-exporter"):
        path = nuc.succeed(f"readlink -f /etc/systemd/system/{unit}.service").strip()
        closure = nuc.succeed(f"nix-store -qR {path}").split()
        status, out = nuc.execute(f"grep -rlFI {NAS_IP} {' '.join(closure)}")
        print(f"{unit}: grep exited {status}: {out!r}")
        assert status == 1, (unit, status, out)
    # Control: the same search finds it in the test's own copy, which the
    # boot-time file rules refer to.
    rules = nuc.succeed("readlink -f /etc/tmpfiles.d/00-nixos.conf").strip()
    found = nuc.succeed(f"grep -rlFI {NAS_IP} $(nix-store -qR {rules})")
    assert "dns-test-nas-targets" in found, found

with subtest("a name that returns a real address fails the blocking probe"):
    # Control for the NAS's pass above: the router stand-in answers the
    # probe name with a real address, which the pass pattern must reject.
    assert dig("doubleclick.net", server=ROUTER_IP) == "192.0.2.31"
    assert dig("doubleclick.net", server=NAS_IP) == "0.0.0.0"

with subtest("an empty blocklist fails the blocking probe, not the resolving one"):
    nuc.succeed("/run/booted-system/specialisation/no-lists/bin/switch-to-configuration test")
    nuc.wait_for_open_port(53, NUC_IP)
    wait_for_probe("dns_blocked", "nuc", 0)
    wait_for_probe("dns_resolve", "nuc", 1)
    # The NAS is untouched.
    wait_for_probe("dns_blocked", "nas", 1)
    nuc.succeed("/run/booted-system/bin/switch-to-configuration test")
    nuc.wait_for_open_port(53, NUC_IP)
    # The lists load again after Blocky starts.
    wait_for_probe("dns_blocked", "nuc", 1, timeout=300)
