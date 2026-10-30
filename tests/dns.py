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

PROM_FILE = "/var/lib/prometheus-node-exporter-text/dns-watch.prom"


def metric(selector):
    """The value of a series in the watch's file (as written), or None."""
    out = nuc.succeed(f"cat {PROM_FILE} 2>/dev/null || true")
    for line in out.splitlines():
        if line.startswith(selector + " "):
            return float(line.split()[-1])
    return None


def wait_for_metric(selector, condition, timeout=240):
    """Wait until the series satisfies the condition, ">0", ">4" or "==1".
    The watch runs every minute and Blocky writes the log in 30-second
    batches."""
    m = re.match(r"(>=|<=|==|>|<)\s*(.+)", condition)
    assert m, condition
    op, ref = m.groups()
    ok = {
        ">": lambda a, b: a > b, "<": lambda a, b: a < b, "==": lambda a, b: a == b,
        ">=": lambda a, b: a >= b, "<=": lambda a, b: a <= b,
    }[op]

    def check(_last_try):
        value = metric(selector)
        return value is not None and ok(value, float(ref))

    with nuc.nested(f"waiting for {selector} {condition}"):
        retry(check, timeout)


def psql(sql):
    """Run SQL as the superuser, through a quoted heredoc so that quotes and
    backslashes reach PostgreSQL as written."""
    return nuc.succeed(f"sudo -u postgres psql -At blocky <<'SQL'\n{sql}\nSQL").strip()


with subtest("the watch runs as dns-watch and its queries work"):
    # Blocky writes in batches, so the first rows may take a moment.
    dig("watch-warmup.example.test")
    nuc.wait_until_succeeds("systemctl start dns-watch.service", timeout=120)
    wait_for_metric("homeserver_dns_watch_success", "==1", timeout=120)
    # Peer authentication mapped the dynamic user to the role of its name.
    assert nuc.succeed("systemctl show -P User dns-watch.service").strip() == "dns-watch"
    print(nuc.succeed(f"cat {PROM_FILE}"))
    # Prometheus (through node-exporter) has it too.
    nuc.wait_until_succeeds(
        "curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=homeserver_dns_watch_success'"
        " | grep -qF '\"1\"]'",
        timeout=180,
    )

with subtest("record what Blocky writes for blocks and NXDOMAIN"):
    dig("threat.test")
    dig("ad.test")
    client.succeed(f"dig +time=2 +tries=1 @{NUC_IP} use-application-dns.net")
    nuc.wait_until_succeeds(
        "sudo -u postgres psql -At blocky -c "
        "\"select 1 from log_entries where question_name like 'use-application-dns.net%'\" | grep -qx 1",
        timeout=90,
    )
    print(psql(
        "select reason, response_type, response_code, count(*) from log_entries "
        "group by 1, 2, 3 order by 4 desc"
    ))
    print(psql("select client_ip, client_name, question_name from log_entries where question_name like 'threat.test%'"))

with subtest("a threat-list lookup becomes a metric naming the client and domain"):
    dig("threat.test")
    # The client has no name at the router, so its label is its address.
    wait_for_metric('homeserver_dns_threat_blocks{client="%s",domain="threat.test"}' % CLIENT_IP, ">0")

with subtest("random subdomains of one threat domain are one series"):
    # Blocked, as a generated name under a threat domain would be.
    assert dig("rnd-first.sub.threat.test") == "0.0.0.0"
    for i in range(30):
        client.execute(f"dig +short +time=2 +tries=1 @{NUC_IP} rnd{i}.sub.threat.test")
    wait_for_metric('homeserver_dns_threat_blocks{client="%s",domain="threat.test"}' % CLIENT_IP, ">20")
    lines = [
        l for l in nuc.succeed(f"cat {PROM_FILE}").splitlines()
        if l.startswith("homeserver_dns_threat_blocks{") and f'client="{CLIENT_IP}"' in l
    ]
    print(lines)
    assert len(lines) == 1 and 'domain="threat.test"' in lines[0], lines

with subtest("only the top 5 domains per client are kept, the rest rolled up"):
    for n in range(8):
        psql(
            "insert into log_entries (request_ts, client_ip, client_name, duration_ms, reason, response_type, "
            "question_type, question_name, effective_tldp, answer, response_code, hostname) "
            f"select now(), '198.51.100.20', '198.51.100.20', 1, 'BLOCKED (threats)', 'BLOCKED', 'A', "
            f"'x.top{n}.test', 'top{n}.test', '0.0.0.0', 'NOERROR', 'nuc' from generate_series(1, {10 - n})"
        )
    nuc.succeed("systemctl start dns-watch.service")
    prom = nuc.succeed(f"cat {PROM_FILE}")
    mine = [l for l in prom.splitlines() if 'client="198.51.100.20"' in l and "threat_blocks" in l]
    print(mine)
    assert len(mine) == 6, mine
    # top5..top7 have 5+4+3 = 12 rows between them, summed.
    assert 'domain="(other)"} 12' in "\n".join(mine), mine
    assert 'domain="top0.test"} 10' in "\n".join(mine), mine

with subtest("an ad block is not a threat"):
    dig("ad.test")
    nuc.wait_until_succeeds(
        "sudo -u postgres psql -At blocky -c "
        "\"select 1 from log_entries where question_name like 'ad.test%'\" | grep -qx 1",
        timeout=90,
    )
    nuc.succeed("systemctl start dns-watch.service")
    prom = nuc.succeed(f"cat {PROM_FILE}")
    assert 'domain="ad.test"' not in prom, prom
    # Control: the threat above is still in the same file, so the file was
    # written after the ad block was logged.
    assert 'domain="threat.test"' in prom, prom

with subtest("an NXDOMAIN burst raises the recent rate"):
    # home.arpa goes to the router, which answers no such name for the
    # unknown ones (example.test would answer for every subdomain).
    for i in range(50):
        client.execute(f"dig +short +time=2 +tries=1 @{NUC_IP} nx{i}.home.arpa")
    wait_for_metric('homeserver_dns_nxdomain_recent{client="%s"}' % CLIENT_IP, ">4")
    # The baseline is present beside it (the rule joins on the two).
    assert metric('homeserver_dns_nxdomain_baseline{client="%s"}' % CLIENT_IP) is not None

INSERT_ROW = (
    "insert into log_entries (request_ts, client_ip, client_name, duration_ms, reason, response_type, "
    "question_type, question_name, effective_tldp, answer, response_code, hostname) "
    "values ({when}, '{ip}', '{ip}', 1, 'RESOLVED', 'RESOLVED', 'A', "
    "'{ip}.test', 'test', 'A (192.0.2.1)', 'NOERROR', 'nuc')"
)

with subtest("a client's first entry in the last 10 minutes makes it new"):
    # A client the log has never seen: one row, as Blocky would write it.
    psql(INSERT_ROW.format(when="now()", ip="198.51.100.7"))
    # Negative control: the log is only minutes old (this test just started
    # it), so nobody is new, as after an install or a trim.
    assert int(psql("select count(*) from log_entries where request_ts < now() - interval '1 hour'")) == 0
    nuc.succeed("systemctl start dns-watch.service")
    assert "homeserver_dns_new_client{" not in nuc.succeed(f"cat {PROM_FILE}")
    # A log that has history: one row two days old, for another client.
    psql(INSERT_ROW.format(when="now() - interval '2 days'", ip="198.51.100.6"))
    wait_for_metric('homeserver_dns_new_client{client="198.51.100.7"}', "==1")
    # The real client's first entry was at the start of the test: it is new
    # only if that is under 10 minutes ago. Either way the metric must agree
    # with the log, so a client that is not new has no series.
    age = float(psql(
        "select extract(epoch from now() - min(request_ts)) from log_entries "
        f"where client_ip = '{CLIENT_IP}'"
    ))
    print(f"the client's first entry is {age:.0f} s old")
    value = metric('homeserver_dns_new_client{client="%s"}' % CLIENT_IP)
    if age < 540:
        assert value == 1, value
    elif age > 660:
        assert value is None, value
    # Control: a client whose first entry is an hour old is not new, though
    # it asks now too.
    for when in ("now() - interval '1 hour'", "now()"):
        psql(INSERT_ROW.format(when=when, ip="198.51.100.8"))
    nuc.succeed("systemctl start dns-watch.service")
    assert metric('homeserver_dns_new_client{client="198.51.100.8"}') is None
    assert metric('homeserver_dns_new_client{client="198.51.100.7"}') == 1

with subtest("a failing query writes success 0 and the unit still succeeds"):
    nuc.succeed("systemctl stop postgresql")
    nuc.succeed("systemctl start dns-watch.service")
    assert metric("homeserver_dns_watch_success") == 0
    nuc.succeed("systemctl start postgresql")
    nuc.wait_for_unit("postgresql.service")
    nuc.wait_until_succeeds("systemctl start dns-watch.service")
    wait_for_metric("homeserver_dns_watch_success", "==1", timeout=120)

with subtest("label values are escaped"):
    # A client name with a backslash and a double quote in it (a real one
    # can't, but the file must stay valid whatever the log holds).
    psql(
        "insert into log_entries (request_ts, client_ip, client_name, duration_ms, reason, response_type, "
        "question_type, question_name, effective_tldp, answer, response_code, hostname) "
        "values (now(), '198.51.100.9', 'a\\b\"c', 1, 'BLOCKED (threats)', 'BLOCKED', 'A', "
        "'esc.test', 'esc.test', '0.0.0.0', 'NOERROR', 'nuc')"
    )
    nuc.succeed("systemctl start dns-watch.service")
    prom = nuc.succeed(f"cat {PROM_FILE}")
    print(prom)
    assert 'client="a\\\\b\\"c",domain="esc.test"' in prom, prom

with subtest("the query log's size is exported"):
    size = int(psql("select pg_total_relation_size('log_entries')"))
    value = metric("homeserver_dns_querylog_bytes")
    print(size, value)
    assert value is not None and value > 0 and abs(value - size) < 0.1 * size, (size, value)

def cap_script():
    """The cap job's script, which holds the cap it was configured with."""
    unit = nuc.succeed("systemctl cat dns-querylog-cap.service")
    m = re.search(r"^ExecStart=(\S+)", unit, re.M)
    assert m, unit
    return nuc.succeed(f"cat {m.group(1)}")


with subtest("the cap deletes the oldest rows, and nothing while under it"):
    # Filler rows, oldest first, about 400 bytes each: some 4 MB with their
    # indexes, over the 2 MB cap of the specialisation below and far under
    # the default cap of 10 GB. Their timestamps are 3 to 10 days old, older
    # than anything the test itself logged, and inside the 14-day retention.
    psql(
        "insert into log_entries (request_ts, client_ip, client_name, duration_ms, reason, response_type, "
        "question_type, question_name, effective_tldp, answer, response_code, hostname) "
        "select now() - interval '10 days' + i * interval '1 minute', '203.0.113.9', '203.0.113.9', 1, "
        "'RESOLVED', 'RESOLVED', 'A', 'filler-' || i || '.' || repeat('x', 200) || '.test', 'test', "
        "'A (192.0.2.1)', 'NOERROR', 'nuc' from generate_series(1, 10000) i"
    )
    # As autovacuum would: the job reads the planner's row estimate.
    psql("analyze log_entries")
    rows = int(psql("select count(*) from log_entries"))
    size = int(psql("select pg_total_relation_size('log_entries')"))
    print(f"{rows} rows, {size} bytes")
    assert size > 2_000_000, size
    # Negative control: under the default cap the job deletes nothing and
    # vacuums nothing.
    assert "cap=10000000000" in cap_script(), cap_script()
    nuc.succeed("systemctl start dns-querylog-cap.service")
    assert int(psql("select count(*) from log_entries")) >= rows
    assert psql("select count(*) from log_entries where question_name like 'filler-1.%'") == "1"
    assert psql("select last_vacuum is null from pg_stat_user_tables where relname = 'log_entries'") == "t"

    nuc.succeed("/run/booted-system/specialisation/tiny-querylog-cap/bin/switch-to-configuration test")
    assert "cap=2000000 " in cap_script(), cap_script()
    nuc.succeed("systemctl start dns-querylog-cap.service")
    left = int(psql("select count(*) from log_entries"))
    print(f"{left} rows left")
    assert left < rows * 0.7, (left, rows)
    # The oldest are gone, the newest remain, deleted in time order.
    assert psql("select count(*) from log_entries where question_name like 'filler-1.%'") == "0"
    assert psql("select count(*) from log_entries where question_name like 'filler-10000.%'") == "1"
    assert psql("select count(*) from log_entries where question_name like '198.51.100.7.test%'") == "1"
    # Vacuumed (DELETE alone frees no file space).
    nuc.wait_until_succeeds(
        "sudo -u postgres psql -At blocky -c "
        "\"select last_vacuum is not null from pg_stat_user_tables where relname = 'log_entries'\" | grep -qx t",
        timeout=60,
    )
    # The live data is under the cap: rewritten compactly, the table and its
    # indexes fit. (The file itself does not shrink without this.)
    psql("vacuum full log_entries")
    live = int(psql("select pg_total_relation_size('log_entries')"))
    print(f"live size {live} bytes")
    assert live < 2_000_000, live
    # Control: the job is idempotent, a second run under the cap deletes
    # nothing more.
    nuc.succeed("systemctl start dns-querylog-cap.service")
    # Not "== left": Blocky keeps logging the probes' lookups meanwhile, and a
    # row landing between the two counts failed this once (#164, Task 6).
    assert int(psql("select count(*) from log_entries")) >= left
    assert psql("select count(*) from log_entries where question_name like 'filler-10000.%'") == "1"
    # A cap far below the table never empties it: at least 1000 rows stay.
    m = re.search(r"-f (\S+)", cap_script())
    assert m, cap_script()
    sql_file = m.group(1)
    nuc.succeed(f"sudo -u postgres psql -q -d blocky -v cap=1000 -f {sql_file}")
    kept = int(psql("select count(*) from log_entries"))
    print(f"{kept} rows after a 1000-byte cap")
    assert kept >= 1000, kept
    # An empty table over the cap: the job ends cleanly.
    psql("delete from log_entries")
    nuc.succeed(f"sudo -u postgres psql -q -d blocky -v cap=1000 -v ON_ERROR_STOP=1 -f {sql_file}")
    assert psql("select count(*) from log_entries") == "0"
    nuc.succeed("/run/booted-system/bin/switch-to-configuration test")

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
    # dns-watch (the alert queries) is a dynamic user that exists only while
    # its unit runs, so check the privileges rather than connecting as it.
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

with subtest("precondition: the router and NAS stand-ins answer the probe name as intended"):
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


def grafana_get(path):
    return json.loads(
        nuc.succeed(f"curl -fsS -u admin:{GRAFANA_PASSWORD} http://127.0.0.1:3000{path}")
    )


def prom_query(query):
    """The result vector of an instant query against Prometheus."""
    out = nuc.succeed(
        "curl -fsS -G http://127.0.0.1:9090/api/v1/query --data-urlencode "
        f"'query={query}'"
    )
    return json.loads(out)["data"]["result"]


def panel_targets(dashboard):
    """Every (panel title, target) of the dashboard, rows' children included."""
    todo = list(dashboard["panels"])
    while todo:
        panel = todo.pop(0)
        todo.extend(panel.get("panels", []))
        for target in panel.get("targets", []):
            yield panel["title"], target


def run_target(target, device):
    """Run one panel target through Grafana's /api/ds/query, as the browser
    would. Template variables are filled in by the browser, not the server,
    so the test fills in `client`; the time macros are the server's."""
    q = dict(target)
    for key in ("expr", "rawSql"):
        if key in q:
            q[key] = q[key].replace("${client}", device).replace("$client", device)
    q["intervalMs"] = 15000
    q["maxDataPoints"] = 500
    body = json.dumps({"queries": [q], "from": "now-6h", "to": "now"})
    out = nuc.succeed(
        f"curl -sS -u admin:{GRAFANA_PASSWORD} -H 'Content-Type: application/json'"
        f" -d @- http://127.0.0.1:3000/api/ds/query <<'JSON'\n{body}\nJSON"
    )
    return json.loads(out)


with subtest("the exporters are scraped and up"):
    for job in ("blocky", "unbound"):
        nuc.wait_until_succeeds(
            "curl -fsS -G http://127.0.0.1:9090/api/v1/query"
            f" --data-urlencode 'query=up{{job=\"{job}\"}}'"
            " | grep -F '\"value\":[' | grep -qF '\"1\"]'",
            timeout=180,
        )
    # The exporter's own view of the control socket, not just its web page.
    nuc.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9167/metrics | grep -E '^unbound_up 1'", timeout=60
    )

with subtest("the DNS dashboard's panels all query without error"):
    # Fresh lookups, so the query-log panels have rows, and then wait for
    # Blocky's 30-second batch to write them.
    for name in ("example.test", "ad.test", "threat.test"):
        dig(name)
    nuc.wait_until_succeeds(
        "sudo -u postgres psql -At blocky -c "
        "\"select 1 from log_entries where question_name like 'threat.test%'\" | grep -q 1",
        timeout=120,
    )
    dash = grafana_get("/api/dashboards/uid/dns")["dashboard"]
    assert dash["uid"] == "dns", dash["uid"]
    targets = list(panel_targets(dash))
    print(f"{len(targets)} targets in {len(dash['panels'])} panels")
    assert len(targets) >= 10, targets
    device = CLIENT_IP
    for title, target in targets:
        result = run_target(target, device)
        errors = [r["error"] for r in result["results"].values() if "error" in r]
        assert not errors, (title, target, errors)
    # The `client` variable's own query.
    var = next(v for v in dash["templating"]["list"] if v["name"] == "client")
    names = run_target({"refId": "A", "datasource": var["datasource"], "format": "table",
                        "rawSql": var["query"]}, device)
    frame = names["results"]["A"]["frames"][0]["data"]["values"]
    print(frame)
    assert CLIENT_IP in frame[0], frame

with subtest("query-log panels return rows; the Prometheus ones return series"):
    for title, target in targets:
        if target["datasource"]["uid"] != "dns-querylog":
            continue
        result = run_target(target, device)
        frames = result["results"][target["refId"]]["frames"]
        rows = sum(len(f["data"]["values"][0]) for f in frames if f["data"]["values"])
        print(f"{title}: {rows} rows")
        # "New names" is empty by design when everything was seen before.
        if "New names" not in title:
            assert rows > 0, (title, result)
    # An empty result is not an error, so a misspelt metric name in a panel
    # would pass above. Every metric the panels use must exist.
    for name in (
        "blocky_query_total", "blocky_response_total", "blocky_cache_hits_total",
        "blocky_cache_misses_total", "blocky_request_duration_seconds_bucket",
        "blocky_denylist_cache_entries", "unbound_cache_hits_total",
        "unbound_cache_misses_total", "unbound_recursion_time_seconds_avg",
        "unbound_answers_bogus",
    ):
        assert prom_query(name), f"no series for {name}"
