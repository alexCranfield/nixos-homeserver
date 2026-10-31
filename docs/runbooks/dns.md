# DNS: Blocky and Unbound

Ticket 7.x (#164). The nuc is the LAN's (local area network's) DNS (Domain
Name System) server: Blocky answers on port 53, blocks ads and threats, and
sends everything else to Unbound, which resolves from the root servers. The
reasons are in
[ADR (Architecture Decision Record) 0012](../adr/0012-lan-dns-blocky-unbound.md),
the design in `docs/superpowers/specs/2026-10-29-lan-dns-design.md`. The configuration is
`modules/dns/` (Blocky, Unbound, the query log, the watch) and
`hosts/nuc/dns.nix` (the secrets). The alert rules are in
`modules/observability/rules.nix`, the dashboard in
`modules/observability/dashboards/dns.json`.

## How a lookup flows

```
LAN device --> Blocky (lan0:53) --> Unbound (127.0.0.1:5335) --> root, TLD, authoritative servers
                 |
                 +-- on a blocklist ------------> 0.0.0.0 (blocked)
                 +-- a declared local name -----> its address
                 +-- home.arpa, and reverse names
                     for 192.168.1.0/24 ---------> the router (192.168.1.1)
```

TLD (top-level domain) servers are the ones for `.com`, `.org` and so on.
Blocky asks the router for each client's name, so the query log shows
device names; a device the router has no reverse name
for shows its address, which is expected.

The nuc's own lookups do not use any of this. Its resolver is the router
(`hosts/nuc/network.nix`), so its boot, comin, the alert relay and the
blocklist downloads never depend on Blocky. The NAS (network-attached
storage) is changed by hand to do the same, below.

## What runs where

| Service | Listens on | What it does |
|---|---|---|
| Blocky | 192.168.1.131, UDP (User Datagram Protocol) and TCP (Transmission Control Protocol) 53, on `lan0` only; HTTP (Hypertext Transfer Protocol) for its API (application programming interface) and metrics on 127.0.0.1:4000 | Blocks, answers local names, forwards |
| Unbound | 127.0.0.1:5335 | Recursion with DNSSEC (DNS Security Extensions) validation |
| Unbound's exporter | 127.0.0.1 | Cache, recursion time and DNSSEC failures for Prometheus |
| PostgreSQL | its socket in `/run/postgresql` only, no network address | Blocky's query log |

The nuc's address is the router's DHCP (Dynamic Host Configuration Protocol)
reservation (`docs/runbooks/network.md`). It is what the router hands out as
the DNS server, so it must not change. The firewall opens port 53 on `lan0`
alone, never on `tailscale0`.

Blocky and Unbound failures post to the alerts channel like other watched
units ([notifications runbook](notifications.md)). Blocky keeps retrying to
start, 5 seconds apart at first and backing off to once a minute, with no
start limit: after a power cut the nuc may boot before the router has
leased it its address, and a Blocky that gave up would stay down. A Blocky
that never comes up is reported by the probe alert `DnsServerDown`.

## Checks on the nuc after deploy, before the router change

Run these once comin has deployed, from the workstation or the nuc as noted.
Only when all pass does Alex change the router's DHCP.

1. **Blocky answers on `lan0` from another LAN device, and blocks.** From the
   workstation (or any LAN device with `dig`; in the dev shell
   `nix shell nixpkgs#dnsutils -c dig ...`):

   ```bash
   dig +short @192.168.1.131 example.com        # a real address
   dig +short @192.168.1.131 doubleclick.net    # 0.0.0.0, on StevenBlack's list
   ```

   Anything but `0.0.0.0` for the second means the lists did not load:
   `journalctl -u blocky -b` on the nuc.
2. **Unbound resolves recursively and rejects a broken DNSSEC name.** On the
   nuc, asking Unbound directly:

   ```bash
   dig @127.0.0.1 -p 5335 example.com +dnssec     # NOERROR; the "ad" flag shows a validated answer
   dig @127.0.0.1 -p 5335 dnssec-failed.org       # SERVFAIL: a name published with bad signatures
   ```

   `journalctl -u unbound -b` says why the second failed
   (`log-servfail` is on). If the first has no `ad` flag, check that the
   name is signed before suspecting Unbound. `dnssec-failed.org` is a
   zone published to fail validation; if it stops being maintained and
   answers normally, pick a current deliberately broken DNSSEC test zone
   (for example `sigfail.verteiltesysteme.net`, if it still exists) and
   confirm it fails with a
   validating resolver elsewhere before trusting the result.
3. **`home.arpa` reaches the router, not the special-use answer.**

   ```bash
   dig +short @192.168.1.131 nuc.home.arpa     # the nuc's address (192.168.1.131)
   ```

   An empty answer or a "no such name" answer here means Blocky's special-use handling
   caught the name first; the VM test cannot show it (it turns that
   handling off), so this is its only check.
4. **Device names appear in the query log.** On the nuc:

   ```bash
   sudo -u postgres psql blocky -c \
     "select client_name, client_ip, count(*) from log_entries group by 1, 2 order by 3 desc limit 10"
   ```

   After step 1, the workstation's lookups should be there under its router
   name. Blank names are devices the router has no reverse name for.
5. **The nuc's own resolver is the router, not Blocky:**

   ```bash
   resolvectl status lan0      # "DNS Servers: 192.168.1.1" and nothing else
   resolvectl query example.com
   ```

6. **The dashboard fills in** ([below](#the-dashboard)) and the DNS alerts are
   quiet.

## The router and the NAS (Alex)

Menu names are from the UniFi Network application and may move between
versions. The router is a UniFi Dream Router 7.

1. **DHCP hands out two DNS servers:** the nuc first, the NAS second.
   Settings, then Networks, then the LAN network, then DHCP name server,
   manual. Devices pick it up when their DHCP lease renews (up to a day);
   disconnecting and reconnecting a device's Wi-Fi or network is faster.
2. **The NAS resolves through the router.** On the NAS, outside this
   repository, set its resolver to the router's address (192.168.1.1), so
   its alert emails never wait on a DNS server it is also serving. From the
   NAS, check that it answers and gets the router's own view:

   ```bash
   nslookup nuc.home.arpa     # the nuc's reserved address, from the router
   ```

3. **The old Pi-hole keeps running as the secondary.** Stopping it (with the
   nuc up) changes nothing for clients. That is an acceptance check, not a
   removal.
4. **Block outbound DNS from the LAN, except from the nuc and the NAS.**
   Two firewall rules on the router, from the LAN to the internet: drop TCP and UDP
   port 53, and TCP port 853 (DNS over TLS, Transport Layer Security), from
   every source other than the nuc and the NAS. Devices with built-in DNS
   servers (Chromecasts, some TVs and apps) would otherwise ask 8.8.8.8
   directly and skip the blocking. DNS over HTTPS (Hypertext Transfer
   Protocol Secure) cannot be blocked this way; the nuc answers NXDOMAIN
   (the "no such name" answer) for `use-application-dns.net`, which tells
   Firefox not to turn its own on, and the rest is accepted.

   Do this after step 1 has settled, so a device whose lease has not renewed
   yet is not cut off. Devices that misbehave afterwards are recorded here:

   | Device | What happened | Fix |
   |---|---|---|
   | _none recorded yet_ | | |

   The Google Home speakers, cameras and Pixels use 8.8.8.8 directly, so
   check them first. A speaker that falls back to the DHCP-given server
   works; one that does not needs an exception on the router.
5. **Check a client's DNS servers.** On Windows `ipconfig /all`, on a Mac
   `scutil --dns`, on Linux `resolvectl status`: the first is the nuc,
   the second the NAS. A third, such as a public resolver or the router
   itself, is a leak; on a phone it may be the router's IPv6 address
   (see [Turning IPv6 on](#turning-ipv6-on-later)).
6. **Record the acceptance checks on #164:** both servers resolve and block
   for a client, the Pi-hole stopped changes nothing, the dashboard shows
   the household's devices.

DHCP itself stays with the router. A fault there, such as it no longer
handing out the nuc's address, is something the nuc cannot see. Check it by
hand with the client check above.

## Undoing it

If the nuc's DNS misbehaves, the fastest fix is on the router, not on the
nuc: set DHCP's DNS servers back to the NAS only (the step above, with the
nuc removed). Devices follow when their lease renews, up to a day; a device
reconnected to Wi-Fi or its network follows at once. Then fix the nuc, and
switch back by adding it as the first server again.

The firewall rules in step 4 can stay: the NAS is excepted from them. If the
nuc is the problem and the NAS is too, remove those rules first, or devices
with built-in DNS servers are the only ones that still resolve.

## During a nuc reboot

The nuc reboots weekly (Tuesday 09:55 UTC, [updates](updates.md)) and on
some deploys. The NAS answers meanwhile. Many devices wait a second or two on
the nuc before trying the NAS, so the network feels slightly slow for a few
minutes, mostly on Tuesday mornings. That is expected, not a fault. Nothing
posts for it: the durations of the alerts below ride out a restart.

At boot Blocky answers before its blocklists have loaded (it fails open), so
blocking starts a few seconds later, or, after a power cut with the router's
internet link still down, within about 5 minutes of it coming back (the list
downloads retry for that long). `DnsServerNotBlocking` and `DnsBlocklistEmpty`
wait 15 minutes for that reason.

## What the design accepts

- **The secondary is a blind spot.** Devices that send part of their
  lookups to the NAS even while the nuc is up get no threat alerts and are
  not on the dashboard until the NAS runs the same module. The monitoring
  covers most of the house's lookups, not all.
- **Failover is not instant** (above).
- **DNS over HTTPS cannot be blocked** at the router.
- **Connections made by address, with no lookup, are invisible.** The
  router's own intrusion detection system (IDS) forwarded to the nuc is #176.

## Day to day

### Changing the blocklists

The lists are in `modules/dns/lists.nix`, in two groups: `ads` (StevenBlack,
EasyList, EasyPrivacy, WindowsSpyBlocker: hits are normal and only counted)
and `threats` (HaGeZi's Threat Intelligence Feeds and DandelionSprout's
anti-malware list: a hit means a device tried to reach a known malware,
phishing or command-and-control domain). Edit the file, open a pull request,
merge; comin deploys it. Blocky loads lists at each start and reloads them
every 4 hours. A download that fails is retried 10 times, 30 seconds apart
(about 4.5 minutes), so a power cut that brings the nuc up before the router's
internet link does not leave blocking off until the next reload; a list that
still fails waits for that reload, or `systemctl restart blocky`.

A list must be in a format Blocky 0.29 reads in full: a hosts file, one
domain per line, or `*.name` wildcards. It half-reads the adblock syntax
(`||name^`), blocking the name alone without its subdomains. The `threats`
group matters for the alerts: `DnsThreatBlocked` reads it by name.

Check after a change:

```bash
dig +short @192.168.1.131 <a name on the new list>     # 0.0.0.0
```

The dashboard's "List sizes by group" panel shows how many names each group
loaded. A list that loads empty shows there, and `journalctl -u blocky` names
the lines it could not parse (it tolerates up to 100 a list; DandelionSprout's
hosts file has four IPv6 lines Blocky cannot read).

The list changes planned a week after the cutover, as a separate small
change so the query log shows what is newly blocked:

- HaGeZi's Multi Pro replaces StevenBlack, EasyList and EasyPrivacy, which
  overlap heavily.
- HaGeZi's Windows and Office native tracker list replaces WindowsSpyBlocker.
- HaGeZi's Apple native tracker list is added, for the Macs, and watched for
  a week.

Deliberately not blocked: Google (speakers, cameras, Pixels; HaGeZi publishes
no Google list because it breaks the devices), Nintendo consoles (online play
shares domains with telemetry) and the smart bulbs (their apps need the
cloud). These are watched on the dashboard instead.

### Allowing or denying a site

In `hosts/nuc/default.nix`, beside `homeserver.dns.listenAddresses`:

```nix
homeserver.dns.allow = [ "example.com" ];   # never blocked, whichever list has it
homeserver.dns.deny = [ "example.org" ];    # blocked too, counted as ads
```

Merge and comin deploys. There is no web page to click: this is the whole
point (settings changed in a page would be reverted by the next deploy).

### Adding a local name

A module that provides a service declares its own name next to its own
configuration:

```nix
homeserver.dns.records."grafana.home.arpa" = [ "192.168.1.131" ];
```

A name maps to one or more addresses, IPv4 or IPv6; there are no CNAMEs
(canonical-name aliases). Which domain the names use is #163's decision; nothing declares
one yet. The nuc itself does not resolve these through Blocky.

### Private names and the NAS's address (sops)

Two values must stay out of this public repository and live in
`secrets/dns.yaml`, encrypted:

| Key | Holds | Used by |
|---|---|---|
| `private-hosts` | local names that only the household should resolve (the NAS's own name, for one), as a hosts file: one address, then the name, per line | Blocky, as a systemd credential read at start |
| `nas-address` | the NAS's LAN address, on its own | a Prometheus `file_sd` file the NAS's DNS probes read |

sops-nix decrypts both at activation. Neither reaches the Nix store. Edit
them on the workstation:

```bash
just secrets-edit dns.yaml
```

Add a line to `private-hosts` such as `192.168.1.x some-private-name`, save,
and merge as usual. A changed `private-hosts` restarts Blocky; a changed
`nas-address` is picked up by Prometheus, which watches the file. Never write
either value in the repo, an issue or a pull request ([secrets
runbook](secrets.md)).

### A real domain's DNSSEC breaks

Unbound enforces DNSSEC, so a domain whose owner broke its signatures returns
SERVFAIL (a server failure) and does not load, from every device. Confirm it
is the signatures, not the network:

```bash
dig @127.0.0.1 -p 5335 <domain>              # on the nuc: SERVFAIL
dig @127.0.0.1 -p 5335 <domain> +cd          # checking disabled: an answer
journalctl -u unbound -b | grep <domain>     # why validation failed
```

If `+cd` answers, add the domain to `hosts/nuc/default.nix`:

```nix
homeserver.dns.insecureDomains = [ "broken-signatures.example" ];
```

Unbound then skips validation for that domain only (`domain-insecure`) and
keeps enforcing it everywhere else. Add one when it breaks, never in
advance, and remove it when the owner fixes the zone. The dashboard's DNSSEC
failures panel counts the rejections.

### Special-use domains

Blocky answers NXDOMAIN for the special-use names (RFC, Request for
Comments, 6761 and its kin) before the question reaches Unbound: `.test` and
`.local` among them, and the reverse zones of private addresses other than
192.168.1.0/24 (those go to the router first). A made-up `.test` name for a
service on the LAN will not resolve through the nuc, whatever a record
says. Use a name under `home.arpa`, which Blocky is expected to send to the
router before the special-use check (the VM test turns the special-use
names off, so this is checked after deploy, below), and `dig` any new
record after the deploy to see that it answers. `.local`
belongs to mDNS (multicast DNS) in any case, which needs no DNS server.

## The query log

Blocky writes every lookup (time, device, name, answer, whether it was
blocked) to PostgreSQL, database `blocky`, under `/var/lib/postgresql`.

- **It holds the whole household's browsing.** The household has been told it
  exists. It stays on the nuc, readable by Blocky, Grafana (role `grafana`)
  and the alert queries (role `dns-watch`) alone, over the socket with peer
  authentication: no password. The two readers can SELECT and nothing else.
- **14 days are kept**, by Blocky's own retention.
- **A size cap of 10 GB** (`homeserver.dns.queryLogMaxBytes`). Every ten
  minutes the job `dns-querylog-cap` estimates the live data and, past the
  cap, deletes the oldest rows down to 80 % of it and vacuums. It always
  keeps at least 1000 rows, however small the cap. The 14 days normally
  keep the log far below this; the cap is for a flood.
- **An alert at 2 GB**, `DnsQueryLogLarge` ([below](#the-alerts)).
- **Not backed up.** It is a curiosity log: losing it loses nothing that
  matters. The backups ticket (#26) must exclude `/var/lib/postgresql`
  from what it sends to the NAS.

To look at it by hand on the nuc:

```bash
sudo -u postgres psql blocky
```

### When PostgreSQL is down

Blocky 0.29 tries three times to open the database at start. If PostgreSQL
is down then, it logs queries to its console ("using console as fallback")
and keeps answering DNS; it never tries the database again by itself.
`dns-querylog-reattach` runs every five minutes: if the current Blocky run
fell back and PostgreSQL answers again, it restarts Blocky onto the log. So
a start while PostgreSQL is down loses up to about five minutes of the log
after PostgreSQL returns, plus a second or two without an answer on port 53
at the restart. DNS availability beats the log. To see it:

```bash
journalctl -u dns-querylog-reattach -b
systemctl list-timers dns-querylog-reattach
```

## The dashboard

Grafana ([observability runbook](observability.md#opening-grafana)), folder
`nuc`, dashboard **DNS** (uid `dns`, so `http://nuc:3000/d/dns`). Provisioned
from `modules/observability/dashboards/dns.json`; changes made in the page
are not saved.

From Prometheus: queries per second, share blocked, cache hit rate (Blocky
and Unbound), upstream response time, DNSSEC failures, and list sizes by
group. From the query log: busiest devices, top blocked names, a
**Device** drop-down with that device's lookups and its blocks, and **new
names in the last day**, names the log has never seen before that day, often
the first sign of something suspicious.

## The alerts

They go through #27's Alertmanager and relay to the alerts channel, 🔴 when
they fire and ✅ when they clear ([observability runbook](observability.md#alerts)).
Thresholds and durations are in `modules/observability/rules.nix`, tunable
as `homeserver.alerting.thresholds`. The two servers are probed from the nuc
by the blackbox exporter, with the label `server` set to `nuc` or `nas`.

| Alert | Fires when | For | What to do |
|---|---|---|---|
| `DnsServerDown` | A lookup of `example.com` against `server` fails. A dead NAS matters though nothing visibly breaks: it is noticed on the day the nuc reboots | 2 m | `nuc`: `systemctl status blocky unbound`, `journalctl -u blocky -b`; if it cannot be fixed quickly, [undo it](#undoing-it). `nas`: check the Pi-hole on the NAS |
| `DnsServerNotBlocking` | A name on the lists (`doubleclick.net`, `homeserver.alerting.blockedProbeName`) comes back with a real address, not `0.0.0.0` | 15 m | The lists failed to download or load: `journalctl -u blocky -b`, the dashboard's list sizes. The wait covers the seconds after a boot. If the NAS fired it, check its Pi-hole's lists |
| `DnsNasProbeMissing` | Prometheus has no probe result for the NAS at all, so `DnsServerDown` for it would stay silent. Rendered only when the NAS is probed | 15 m | The `file_sd` file made from the `nas-address` secret is missing, empty or unreadable by `prometheus`: `ls -l` the path in `homeserver.alerting.dnsServers.secondaryTargetsFile`, and check `nas-address` in `secrets/dns.yaml` |
| `DnsBlocklistEmpty` | A blocklist group (`ads` or `threats`) has 0 names loaded, or no series at all while Blocky is scraped. The blocking probe asks for an `ads` name only, so this is the only alert for an empty `threats` group, whose threat alerts would stay silent | 15 m | The dashboard's "List sizes by group" shows which. `journalctl -u blocky -b` names the list that failed to download or parsed to nothing; check the list's URL in `modules/dns/lists.nix` by `curl`. Blocky retries downloads for about five minutes at start and every 4 hours after; `systemctl restart blocky` retries now |
| `DnsThreatBlocked` | A device looked up a name on a `threats` list in the last 5 minutes. Named by device and registrable domain, at most 5 domains a device, the rest as `(other)` | 0 s | It was blocked, but find the device: the dashboard's Device drop-down shows what else it asked. A phished link or an infected device. A false positive is allowed in `homeserver.dns.allow` |
| `DnsNxdomainBurst` | A device gets more than 10 "no such name" answers a minute, over 10 minutes, and more than 5 times its own 7-day baseline. Malware generating domain names to find its controller does this, and so do broken devices | 5 m | Look at the device's lookups on the dashboard. A device with a misconfigured name (a stale server address) is the common cause |
| `DnsNewClient` | A client address appears whose first query in the log is under 10 minutes old, and the log itself is over an hour old (a fresh or trimmed log would flag everything) | 0 s | A guest, a new device, or something that should not be on the network. Check the router's client list |
| `DnsWatchFailing` | The timer that feeds the three alerts above is not working: its queries fail (`homeserver_dns_watch_success` is 0), it never wrote its file, or the file is over 5 minutes old (the timer is stuck and the old values are still there) | 10 m | The threat, burst and new-client alerts and the log-size alert are blind meanwhile. `journalctl -u dns-watch -b`, `systemctl status postgresql`; the failing query is in the journal |
| `DnsQueryLogLarge` | The query log table with its indexes is over 2 GB (`homeserver_dns_querylog_bytes`); 14 days of use should need far less | 15 m | A client is flooding the server: the dashboard's busiest devices. The 10 GB cap will start deleting the oldest rows. Look at the device, not the cap |

`DnsFailing`, from #27, stays: it probes the nuc's own resolver, which is the
router. After this change it watches that path. `GatewayUnreachable` holds
it back, as before.

The three alerts built on the log come from `dns-watch`, a timer that runs
every minute, queries PostgreSQL (`modules/dns/watch.sql`) and writes
Prometheus text for node-exporter, since Prometheus cannot query PostgreSQL.
The alert noise is reviewed with #27's, due 2026-11-05.

## Turning IPv6 on later

This ticket is IPv4 only: the router hands out no IPv6 DNS server today. If
IPv6 is turned on at the router, UniFi by default advertises the router
itself as an IPv6 DNS server, and devices would send some lookups there:
unblocked and missing from the query log, with nothing visibly broken.
Prepared for: Blocky's listen addresses are one option (a list), and the
firewall rule is on `lan0`, so it already covers IPv6. The rest is #175, done
in one change with the router setting: a fixed ULA (unique local address) for
the nuc, Blocky listening on it, the router advertising it instead of itself,
and a check that nothing new is reachable from outside.

## Follow-ups

- **#175** — IPv6 without DNS leaks (above).
- **#176** — the router's IDS events forwarded to the
  nuc: connection-level detection, which DNS cannot see.
- **#177** — a separate IoT (Internet of Things) network for the smart bulbs
  and cameras, so a compromised one cannot reach the PCs or the NAS.
- **#163** — the naming scheme and HTTPS for admin interfaces.
- **#26** — backups, which must exclude the query log.

## Tested in a VM (virtual machine)

`nix build .#checks.x86_64-linux.dns` boots the nuc configuration beside
stand-ins for the router and a LAN client, with local lists and an upstream
the test controls (the VM has no internet). Each check has a negative
control. It covers: blocking and allowing, local and private names (and that
the private ones are not in the Nix store), the `use-application-dns.net`
answer, port 53 on `lan0` and not on a tailnet-like interface, loopback-only
ports, the nuc's resolver not being Blocky, queries landing in PostgreSQL
with the read-only roles unable to write, the cap and the reattach timer,
the probes, every alert firing and resolving, and the dashboard's queries.
Recursion and DNSSEC are the checks on the nuc above.
