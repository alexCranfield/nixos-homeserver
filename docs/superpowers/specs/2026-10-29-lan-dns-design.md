# LAN DNS design (ticket 7.x, #164)

Date: 2026-10-29. Status: approved by Alex 2026-10-30.

## Intent

The house's DNS (Domain Name System) server moves to the nuc, declared in
Nix: ad and tracker blocking, a local recursive resolver, and names for the
nuc's services. Today it is a Pi-hole container on the NAS, set up by hand.
Moving it puts the blocklists and settings in the flake, gives the house a
second server for the first time, and lets the NAS be rebuilt without taking
the house offline.

Alex looks at the blocking out of curiosity: which devices are noisy, and
whether anything is making suspicious connections (Alex, 2026-10-29). The
query view has to serve that, not only the yes/no of "is it working".

### What exists today (surveyed 2026-10-29, read-only)

- The router (a UniFi Dream Router 7) does DHCP (Dynamic Host Configuration
  Protocol) and hands out **one** DNS server: the NAS's Pi-hole. There is no
  secondary. Every device depends on it, **the nuc and the NAS included**.
- The NAS sends its alert emails through its own Pi-hole, and the nuc's
  Discord alerts resolve through it too, so a broken Pi-hole can silence the
  alerts that would report it. The ticket's assumption that the nuc already
  uses the router as its resolver is wrong; this design fixes it.
- The router answers DNS itself, forwarding to its own upstream, not through
  the Pi-hole (it resolved a known ad domain unblocked). It answers reverse
  lookups with device names (`nuc.home.arpa` for the nuc). It does not
  advertise a DNS server over IPv6 (the nuc has only a ULA, unique local,
  IPv6 address and no IPv6 DNS server), so clients can't quietly bypass the
  blocking over IPv6.
- Pi-hole v6: DHCP off, upstream Google (8.8.8.8, 8.8.4.4), no DNSSEC, six
  blocklists (about 2.3 million domains), no allow or deny entries, one
  local record (the NAS's own name). About 56,000 queries a day from 21
  devices; about 15 % blocked, about two-thirds answered from cache.

The six blocklists, all enabled:

1. `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts`
2. `https://v.firebog.net/hosts/Easylist.txt`
3. `https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt`
4. `https://raw.githubusercontent.com/DandelionSprout/adfilt/refs/heads/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareAdGuardHome.txt`
5. `https://v.firebog.net/hosts/Easyprivacy.txt`
6. `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt`

## Goals

- A LAN device gets the nuc as its first DNS server, resolves names, and
  has ads, trackers and malware domains blocked by the six lists above.
- The house keeps resolving while the nuc reboots (weekly, Tuesday 09:55
  UTC, and on some deploys), through the NAS as secondary.
- The alert paths never depend on the server they watch: the nuc and the
  NAS resolve through the router, not through either blocking server.
- Alex can see, in Grafana, which devices query most, what one device looks
  up and has blocked, and names the house has never looked up before.
- An alert on Discord when either server stops resolving, or stops
  blocking.
- Services on the nuc declare their own DNS names next to their own config,
  so a new container (or a development shell later) adds its name in the
  same change.

## Non-goals

- **DHCP.** It stays with the router; the Pi-hole doesn't serve it today.
- **Changing the NAS's DNS server.** It keeps running its Pi-hole as the
  secondary, unchanged, until the NAS moves to NixOS and runs the same Nix
  module (my call: keeps NAS work, which lives outside this repo, out of
  this ticket). The NAS's resolver change (below) is the one NAS step, and
  Alex makes it.
- **The naming scheme and HTTPS for admin interfaces.** That is #163. This
  ticket provides the mechanism for declaring names; #163 decides what the
  names look like (a domain under `home.arpa` can never get a public
  certificate, so this ticket must not lock that in).
- **DNS for the tailnet**, so phones get the blocking away from home. A
  separate ticket: it reverses this ticket's "port 53 not on the tailnet"
  on purpose and fits with #163.
- **Seeing connections, not just lookups** (ntopng, Zeek). Needs port
  mirroring or the nuc in the traffic path; a different project.
- **Encrypted upstream** (DNS over TLS or HTTPS to a public resolver).
  Unbound resolves directly instead, so no one provider sees every lookup.

## Anti-goals

- A DNS failure that silences the alert about it.
- Blocking that leaks: a public resolver handed out beside the nuc, or a
  browser's own DNS over HTTPS going around it.
- Any private name (the NAS's name or address, the tailnet name) in the
  public repo, in clear.
- The query log leaving the nuc, or being readable by anything but Blocky
  and Grafana.
- Settings changed by clicking in a web page, which the next deploy then
  silently reverts.

## Constraints

- Native NixOS services, not containers (ADR 0006 keeps Docker for the game
  servers): `services.blocky`, `services.unbound`, `services.postgresql`,
  `services.prometheus.exporters.unbound`.
- Port 53, UDP and TCP, open on `lan0` only. Not on `tailscale0`, never from
  the WAN. Blocky's HTTP port (API and metrics), Unbound, PostgreSQL and the
  exporter listen on loopback only.
- The nuc's address is the router's DHCP reservation (192.168.1.131,
  `hosts/nuc/network.nix`). It is what the router hands out as the DNS
  server, so it must not change.
- Secrets in sops (ADR 0004); Alex edits the secrets files himself.
- Every module tested in a NixOS VM test that runs in CI, with negative
  controls, as for earlier tickets.

## Design

### The pieces (decided with Alex, 2026-10-29)

- **Blocky** on the nuc, the server devices talk to. Chosen over Pi-hole
  and AdGuard Home because its whole configuration is Nix (nothing to
  click, nothing to drift), it exports Prometheus metrics itself, it has
  no state it needs to answer, and the NAS can later run the same module.
  There is no web page: Grafana is where the queries are seen, and
  unblocking a site is a one-line change in the repo.
- **Unbound** behind Blocky, resolving recursively from the root servers,
  with DNSSEC (DNS Security Extensions) validation, prefetch and
  serve-expired.
- **PostgreSQL**, local, holding Blocky's query log for Grafana.
- **The Unbound exporter**, for Unbound's cache, recursion time and DNSSEC
  failures.

Already present and reused: Prometheus, Grafana, the blackbox exporter,
Alertmanager and the Discord relay (#25, #27).

### How a lookup flows

```
LAN device ──► Blocky (lan0:53) ──► Unbound (127.0.0.1) ──► root, TLD, authoritative servers
                 │
                 ├─ on a blocklist ──► blocked answer
                 ├─ a declared local name ──► its address
                 └─ home.arpa, and reverse lookups for 192.168.1.0/24 ──► the router
```

- Names under `home.arpa` and reverse lookups for the LAN go to the router,
  which knows the DHCP devices' names.
- Blocky asks the router for each client's name, so Grafana shows device
  names, not just addresses.
- The answer `use-application-dns.net` gets is NXDOMAIN, which tells
  Firefox not to switch on its own DNS over HTTPS (Pi-hole does this by
  default; Blocky needs it declared).

### The nuc's and the NAS's own resolvers

- **The nuc** ignores the DNS server DHCP offers and uses the router
  (`networking` / `systemd.network` on `lan0`), so its boot, comin, the
  Discord relay and the list downloads never depend on Blocky or the NAS.
  Its resolver stays systemd-resolved; Blocky binds the LAN address, not
  `127.0.0.53`.
- **The NAS** is changed by Alex, outside this repo, to resolve through the
  router. The runbook says how to check it.

### Blocking

- The six lists above, by URL, in the repo as plain Nix (they are public;
  encrypting them would hide nothing and make every change unreadable).
- An allowlist and a denylist, empty to begin with, in the repo.
- Blocked names get Blocky's default answer (`0.0.0.0` and `::`), as
  Pi-hole gave.
- Lists refresh daily.
- The lists are in two groups, so the log and the alerts can tell them
  apart (Alex, 2026-10-29):
  - **ads**: StevenBlack, EasyList, EasyPrivacy, WindowsSpyBlocker. Hits
    are normal and only counted.
  - **threats**: HaGeZi's Threat Intelligence Feeds and DandelionSprout's
    anti-malware list. A hit means a device tried to reach a known
    malware, phishing or command-and-control domain.
- **Formats Blocky can read.** HaGeZi's `adblock/tif.txt` and
  DandelionSprout's `AntiMalwareAdGuardHome.txt` are in adblock syntax
  (`||example.com^`), which Blocky is believed not to read: they would
  silently block nothing. The builder checks, and if so uses the same
  lists in a domains or hosts format each project publishes (for example
  HaGeZi's `wildcard/tif-onlydomains.txt`). The blocking test uses a name
  from each list, so a list that loads empty fails it.
- **The cutover keeps the same lists**, so it changes nothing users notice
  and "stopping the old Pi-hole changes nothing" means something.

#### List changes a week after the cutover (Alex, 2026-10-29)

A small separate change, so the query log shows what is newly blocked:

- HaGeZi Multi Pro replaces StevenBlack, EasyList and EasyPrivacy, which
  overlap heavily.
- HaGeZi's Windows and Office native tracker list replaces
  WindowsSpyBlocker.
- HaGeZi's Apple native tracker list, for the Macs; watched for a week.

Deliberately not blocked: Google (Home speakers, cameras, Pixels; HaGeZi
publishes no Google list because it breaks the devices), Nintendo consoles
(online play shares domains with telemetry) and the smart bulbs (their
apps need the cloud). These are watched on the dashboard instead. The
Google devices use 8.8.8.8 directly, so they are the first to check after
the router's outbound-DNS rule.

### Local names

- An option, `homeserver.dns.records` (my naming), that each module sets for
  its own service: a name and the address it points to. Blocky answers all
  of them.
- Names that must stay private (the NAS's own name, today's one local
  record) come from a sops secret instead, in a form Blocky reads at start,
  never through the Nix store.
- Which domain the service names use is #163's decision. Until then the
  builder can declare none, or one obvious test name under `home.arpa`.

### The query log

- Blocky writes every query to PostgreSQL on the nuc: time, device, name,
  answer, and whether it was blocked.
- 14 days kept, then deleted by Blocky's own retention (Alex,
  2026-10-29). It holds the whole household's browsing, so it is kept no
  longer than the curiosity use needs, and the household is told it
  exists.
- Not backed up: it is a curiosity log, and losing it loses nothing that
  matters (my call).
- PostgreSQL listens on its local socket only. Blocky writes; Grafana reads
  with a read-only role. Peer authentication over the socket is preferred,
  so no password is needed; if one is, it goes in sops.

### Grafana

A DNS dashboard, provisioned from the repo like the existing ones:

- **From Prometheus:** queries per second, the share blocked, cache hit
  rate (Blocky and Unbound), upstream response time, DNSSEC failures, list
  sizes.
- **From the query log:**
  - the busiest devices, by name;
  - top blocked names;
  - one device's lookups and blocks, chosen from a drop-down;
  - **new names**: names first seen in the last day, never looked up in
    the rest of the log, which is often the first sign of something
    suspicious.

### Alerts

Through #27's Alertmanager and relay, with the same 🔴 and ✅ posts, and
thresholds tunable in `modules/observability/rules.nix` like the others:

- **Each server stops resolving** (the nuc's Blocky and the NAS's Pi-hole,
  probed separately from the nuc by the blackbox exporter). The NAS one
  matters even though nothing visibly breaks: a dead secondary is only
  noticed on the day the nuc reboots.
- **Each server stops blocking**: a name on the lists comes back with a real
  address, for example because the lists failed to download.
- **Unbound failing on its own** shows up as Blocky not resolving; no
  separate alert unless the builder finds a case the other two miss.
- The existing `DnsFailing` (the nuc's own resolver) stays. After this
  change it watches the router path.
- The weekly reboot needs no special case: the nuc's own Prometheus is down
  while it reboots, and the durations ride out the restart.

What the nuc can't see: a fault in the router's DHCP, such as it no longer
handing out the nuc's address. The runbook covers checking it by hand.

### Suspicious-activity alerts (Alex, 2026-10-29)

The blocklists already stop known-bad domains, but nobody is told when
one is hit. From the query log, these alert on Discord, naming the device:

- **A threat-list hit**: any lookup blocked by the threats group, with the
  domain in the post. Event alert, posts at once.
- **An NXDOMAIN burst**: a device whose rate of "no such name" answers jumps
  well above its usual. Malware generating random domain names to find its
  controller does this; so do broken devices. Threshold alert.
- **A new device**: a client address the log has never seen before.

Prometheus can't query PostgreSQL, so a timer on the nuc runs the queries
every minute and writes the counts to node-exporter's textfile directory,
as `tailscale-state` does (`modules/observability/probes.nix`); the rules
alert on those metrics. The exact thresholds are the builder's, tuned in
the noise review like #27's.

Only lookups that reach the nuc are seen. Lookups a device sends to the
NAS (the secondary) aren't in this log until the NAS runs the same module.
Connection-level detection, which DNS can't see, is #176: the router's own
threat detection, forwarded to the nuc.

### Changes on the router and the NAS (Alex)

1. The router's DHCP hands out the nuc as the first DNS server and the NAS as
   the second.
2. The NAS resolves through the router.
3. The old Pi-hole keeps running as the secondary. Stopping it (with the nuc
   up) changes nothing for clients; that is an acceptance check, not a
   removal.
4. Router firewall rules block outbound DNS from the LAN, on port 53 and
   on 853 (DNS over TLS), except from the nuc and the NAS, so devices with
   built-in DNS servers (Chromecasts, some TVs and apps) can't go around
   the blocking (Alex, 2026-10-29). Devices that misbehave afterwards are
   recorded in the runbook. DNS over HTTPS can't be blocked this way; the
   `use-application-dns.net` answer covers Firefox, and the rest is
   accepted.

### What the design accepts (Alex, 2026-10-29)

- **The secondary is a blind spot.** Some devices send part of their
  lookups to the NAS even while the nuc is up. Those get no threat alerts
  and aren't on the dashboard until the NAS runs the same module. The
  monitoring covers most of the house's lookups, not all.
- **Failover isn't instant.** While the nuc reboots, many devices wait a
  second or two on it before trying the NAS, so the network feels slightly
  slow for a few minutes, mostly on Tuesday mornings. Expected, and
  written in the runbook so it isn't mistaken for a fault.

### Undoing it

If the nuc's DNS misbehaves, the fastest fix is on the router: DHCP hands
out the NAS only again. The runbook spells it out step by step, including
how long devices take to pick it up (until they renew their DHCP lease, up
to a day; reconnecting a device's Wi-Fi or network is faster), and how to
switch back once fixed.

### Testing

A VM test, with negative controls, run in CI:

- a client resolves through Blocky; a name on a test list is blocked, one
  not on it is not; an allowlisted name is not blocked;
- a declared local name answers; a private name from the secret answers and
  isn't in the Nix store;
- `use-application-dns.net` gets NXDOMAIN;
- port 53 is reachable on the LAN interface and not on a tailnet-like
  interface; Blocky's HTTP port, Unbound and PostgreSQL aren't reachable
  from outside;
- the nuc's own resolver doesn't use Blocky;
- queries land in PostgreSQL, Grafana's role can read them and can't write;
- the alerts fire and resolve (resolution stopped, blocking broken).

The VM has no internet, so the test uses local list files and an upstream
the test controls, not the real lists or the root servers. Unbound's
recursion and DNSSEC are checked on the nuc after deploy.

### Docs

- An ADR: Blocky and Unbound, and why not Pi-hole or AdGuard Home.
- A runbook, `docs/runbooks/dns.md`: changing the blocklists, allowing a
  site, adding a local name, a private one through sops, the router and
  NAS steps, checking a client's DNS servers, what happens during a nuc
  reboot, reading the dashboard.
- `docs/runbooks/network.md`: the nuc's resolver now ignores DHCP's DNS.
- `docs/PLAN.md`, README and the Q&A log, as for earlier tickets.

### Settled after the builder check (my calls unless marked)

- **The router's address** is 192.168.1.1, fixed in the router's own
  config like the nuc's reservation. One option holds it, used for the
  nuc's resolver, Blocky's `home.arpa` and reverse-lookup forwarding, its
  client-name lookups, and the existing gateway probe. The
  existing `homeserver.alerting.gateway` moves to a shared option such as
  `homeserver.network.router`; the name is the builder's.
- **The NAS's address is private** and never goes through Nix. It reaches
  the probe as a sops secret rendered at runtime into a Prometheus
  `file_sd` target file; the rules match on the job, never the address.
  The nuc already reaches the NAS on port 53 today (it resolves through
  it).
- **Device names:** if the router has no reverse name for a device, the
  log and dashboard show its address. That is expected, not a bug.
- **The nuc's own lookups of declared local names:** none until #163 picks
  a domain. Then systemd-resolved sends only that domain to Blocky, so
  public names still never depend on it.
- **`homeserver.dns.records`:** a name maps to one or more addresses, IPv4
  or IPv6. No CNAMEs until something needs one.
- **IPv4 only.** Blocky listens on the nuc's IPv4 LAN address. The router
  hands out no IPv6 DNS server, so no client would use an IPv6 one.
- **DNSSEC and recursion aren't tested in CI.** A local signed zone in the
  VM would mostly test the test. They are checked on the nuc after
  deploy, with a deliberately broken DNSSEC name as the negative control.
- **PostgreSQL** uses peer authentication over its socket, as the `blocky`
  and `grafana` system users, so no password and no new secret. Its data
  source is provisioned beside the existing ones, with a fixed UID (unique
  identifier) the dashboard refers to.
- **At boot, Blocky resolves before its lists have loaded** (fail open): the
  house keeps working, and blocking starts a few seconds later. The
  "stops blocking" alert's duration is longer than a list load, so a boot
  doesn't post.

### Turning on IPv6 later (Alex, 2026-10-29)

Alex may turn IPv6 on at the router later. When it is on, UniFi by default
advertises the router itself as an IPv6 DNS server, and devices would then
send some lookups there: unblocked and missing from the query log, with
nothing visibly broken. So this ticket stays IPv4-only but prepares for it:

- Blocky's listen addresses are one option (a list), so adding IPv6 is one
  line.
- The firewall rule for port 53 is on `lan0`, so it already covers IPv6.

The rest is #175, done in one change with the router
setting: a fixed ULA address for the nuc (not one from the ISP's prefix,
which can change), Blocky listening on it, the router advertising it as
the IPv6 DNS server instead of itself, and a check that nothing new is
reachable from outside.

## Left to the builder

- Blocky's and Unbound's exact settings: cache sizes, timeouts, Blocky's
  loading strategy when the lists can't be fetched at boot (it must still
  resolve), prefetch details.
- The form of the private-names secret (a hosts file, or a second Blocky
  config file), as long as it never passes through the Nix store.
- Which listed name the blocking probe asks for, and how the alert rules
  are split into the existing groups.
- The dashboard's layout and SQL.

## Checks on the nuc after deploy, before the router change

- Blocky answers on `lan0` from another LAN device; a known ad domain is
  blocked.
- Unbound resolves recursively and rejects a deliberately broken DNSSEC
  name.
- Device names appear in the query log.
- The nuc's own resolver is the router.
- Only then does Alex change the router's DHCP.
