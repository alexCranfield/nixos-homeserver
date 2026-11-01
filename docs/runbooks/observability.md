# Observability: Prometheus and Grafana

Ticket 3.4 (#25). The nuc collects its own metrics and draws them in Grafana,
which Alex opens from his own devices over the tailnet. The configuration is
`modules/observability/default.nix`; the admin password's secret is wired in
`hosts/nuc/observability.nix`. Alert rules on these metrics are ticket 3.6 (#27), in [Alerts](#alerts) below.

## What runs where

Everything is a native NixOS service, not a container (ADR, Architecture
Decision Record, 0006 and its note of 2026-10-27), so the metrics and the
dashboards keep working when Docker is what's broken.

| Service | Listens on | What it does |
|---|---|---|
| Prometheus | 127.0.0.1:9090 | Scrapes node-exporter, cAdvisor, comin's exporter, itself and the two blackbox probes every 15 s; stores the results and evaluates the alert rules every 15 s |
| node-exporter | 127.0.0.1:9100 | The host: CPU, memory, disks, network, temperatures, and each systemd unit's state |
| cAdvisor | 127.0.0.1:9338 | Each container's CPU, memory and network (not its default 8080, which apps and the tests use) |
| comin's exporter | 127.0.0.1:4243 | Fetch, evaluation, build and deployment results |
| Alertmanager | 127.0.0.1:9093 | Groups what Prometheus fires and passes it to the relay; its cluster listener (9094) is off |
| alert relay | 127.0.0.1:9095 | Turns Alertmanager's webhook calls into Discord posts |
| blackbox exporter | 127.0.0.1:9115 | Probes the LAN (local area network) gateway (ping), the nuc's own resolver (a DNS, Domain Name System, lookup) and, from ticket #164, both LAN DNS servers (does each resolve, does each block) for Prometheus |
| Grafana | 127.0.0.1:3000 | Dashboards, the DNS one reading the query log in PostgreSQL; on the tailnet at `http://nuc:3000` through Tailscale Serve |

Nothing here is reachable from the LAN: all of it is
on loopback, and `tests/observability.nix` scans the LAN address to check.
The only way in from outside the nuc is Grafana, through Serve, from devices
the tailnet's access policy allows.

Failures of any of these units post to the alerts channel, like other watched
units (the newer ones too: alertmanager, alert-relay,
prometheus-blackbox-exporter, tailscale-state and minecraft-status) ([notifications runbook](notifications.md)).

## Opening Grafana

From a device on the tailnet with access to `tcp:3000` (your own, under the
policy in the [tailscale runbook](tailscale.md); not share recipients), open
`http://nuc:3000`, or `http://nuc.<tailnet name>.ts.net:3000` where the short
name doesn't resolve. Log in as `admin`. The dashboards are in the `nuc`
folder:

- **Node Exporter Full**: the host (grafana.com dashboard 1860).
- **cadvisor dashboard**: containers, filtered by Compose project and
  container name (grafana.com dashboard 19792).
- **DNS**: the LAN DNS server's queries, blocks, cache and query log ([dns.md](dns.md#the-dashboard)).
- **Game servers**: whether the Minecraft server answers and how long its
  status ping takes (from `minecraft-status`, below), then players online
  over time, then CPU, memory and network of the containers whose names start
  `minecraft`. The last four are full width on one time axis, so a spike in
  one lines up with the others. The players graph draws the count as a line
  and each named player as a stacked band; hover (tooltip in "all" mode) to
  see who was on. Memory is drawn from zero against the stack's own limit
  (`memoryMax`, dashed), so the headroom StackMemoryNearLimit watches is
  visible. Tick rate and heap are still to come (#168).

### Minecraft player count

`minecraft-status.service`, run by a timer every 15 s, asks the server for its
status with `mc-monitor status` (itzg's tool, from the author of the server's
image) on `127.0.0.1:25565`, the port the container publishes, and writes
`homeserver_minecraft_up`, `homeserver_minecraft_players_online` and
`homeserver_minecraft_response_seconds` to node-exporter's textfile
directory, as `tailscale-state` does. It also asks a second time with
`mc-monitor status --json` and exports `homeserver_minecraft_player_online{player="<name>"} 1`
for each name in the ping's player sample (`players.sample`). The sample is
the server's to give: vanilla lists at most 12 names, and a pack can hide it,
so there can be fewer names than the count, or none, and the count is always
the number to trust. Only valid Minecraft names (1 to 16 of letters, digits
and `_`) are kept; anything else is dropped, and `\` and `"` are escaped as
well. The names exist only at runtime, in Prometheus and Grafana, never in
this repo. They are kept for Prometheus's retention window, and anyone who
can open Grafana over the tailnet can see who played and when. When the server does not answer, or is still loading, `up` is 0 and the
other two are absent; the unit does not fail, as that is a result. The
response time includes starting `mc-monitor`, so a few milliseconds are its
own.

It is a host unit, not a container in `stacks/minecraft`, on purpose: a
change to that stack's files makes comin's deploy recreate the server's
container, which kicks everyone off. `mc-monitor export-for-prometheus`
would also listen on every address, where this keeps to loopback. To look at
it by hand:

```bash
cat /var/lib/prometheus-node-exporter-text/minecraft.prom
systemctl status minecraft-status.timer
journalctl -u minecraft-status -b
```

The player count is blank on the dashboard while the server loads (about two
minutes after a start). `tests/observability.nix` runs the timer against a
stand-in server and checks that the dashboard's own queries follow its count.
`mc-monitor` is built from `modules/observability/mc-monitor.nix`, a copy of
nixpkgs' package, because nixos-26.05 does not have it yet.

### Why plain HTTP

The browser marks the page "Not secure". The traffic is still encrypted, end
to end, by Tailscale's WireGuard tunnel; the label is about the missing
certificate. Serve's HTTPS would need a certificate for
`nuc.<tailnet name>.ts.net`, and every public certificate is published in
the Certificate Transparency logs, which would make the tailnet's name public
for good. HTTPS on a name of our own is #163.

## The admin password

It lives in sops: `secrets/observability.yaml`, key `grafana-admin-password`.
To change it:

```bash
just secrets-edit observability.yaml
```

Then merge as usual. When comin deploys, sops-nix writes the new value and
restarts `grafana-admin-password.service`, which sets it in Grafana with
`grafana cli admin reset-admin-password`. The same unit runs after every
Grafana start, so a password changed in Grafana's own UI (user interface) is
put back to the sops one at the next restart. sops is the only place it is
set.

The unit fails, and posts, if Grafana does not report the change: `grafana
cli` exits 0 even when it finds no admin user, so the unit reads its output
instead. To see what happened:

```bash
journalctl -u grafana-admin-password -b
```

Grafana's other secret, the key it encrypts stored credentials with, is made
on the nuc the first time (`/var/lib/grafana/secret_key`) and never leaves
it. Nothing stored needs it today, so a reinstall that makes a new one loses
nothing.

## Dashboards and the data source

Both are provisioned from the repo and can't be changed or deleted in the
UI. A change made there is not saved. To change or add a dashboard:

1. Build it in Grafana (a new, unsaved dashboard is fine), then **Export →
   Export as JSON** (JavaScript Object Notation).
2. Save the JSON under `modules/observability/dashboards/`, set its
   `datasource` references to `{"type": "prometheus", "uid": "prometheus"}`,
   and copy it into the `dashboards` derivation in the module, as
   `game-servers.json` is.
3. For a grafana.com dashboard, fetch it by revision and hash instead, as the
   two there are (`grafanaCom <id> <revision> <hash>`), with the hash from
   `nix-prefetch-url --type sha256 <url>` converted by
   `nix hash convert --hash-algo sha256 <hash>`.
   Replace its `${DS_PROMETHEUS}` placeholder, if any, with `prometheus`.
4. Add its title to the dashboards subtest in `tests/observability.py`.

## Retention and disk

Prometheus keeps 30 days, or 10 GB, whichever comes first, in
`/var/lib/prometheus2` on the root subvolume. At this scale a month is
expected to be 1 to 2 GB. To see the real figure:

```bash
sudo du -sh /var/lib/prometheus2
```

## Checking a target

From the workstation, in the repository's dev shell (which has `jq`; the
nuc doesn't):

```bash
ssh ops@nuc curl -s 127.0.0.1:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'
```

All four jobs (`node`, `cadvisor`, `comin`, `prometheus`) should be `up`.
For a single query:

```bash
ssh ops@nuc "curl -s 127.0.0.1:9090/api/v1/query --data-urlencode query=up" | jq .
```

### cAdvisor shows containers without names

cAdvisor reads Docker's containers through Docker's own containerd, at
`/run/docker/containerd/containerd.sock` (set in the module). Docker 29 needs
this; without it cAdvisor drops Docker and reports containers only as
`/system.slice/docker-<id>.scope`. It also checks for Docker only when it
starts, so it is ordered after Docker and restarts with it. If names go
missing after a Docker change, check the first lines of
`journalctl -u cadvisor -b` for "Registration of the docker container
factory".

## Tailscale Serve

`tailscale-serve-grafana.service` runs `tailscale serve --bg --http=3000
http://127.0.0.1:3000` once the nuc is logged in to the tailnet, and
`tailscale serve --http=3000 off` when it stops. Serve's settings are kept in
`tailscaled`'s state, so removing the unit from the configuration (which stops
it) is what takes the port back. To see what Serve publishes:

```bash
tailscale serve status
```

Serve answers inside `tailscaled`, so the nuc's firewall never sees those
connections. The tailnet's access policy is what limits who reaches 3000;
`tests/tailscale.nix` checks that a policy without `tcp:3000` closes it.

## Alerts

Ticket 3.6 (#27). Prometheus evaluates the rules in
`modules/observability/rules.nix`, Alertmanager groups what fires
(`modules/observability/alerting.nix`), and a small relay
(`modules/observability/alert-relay.py`) posts it to the alerts channel through
`homeserver-notify`, the same sender as the failure messages, so there is no new
secret. A firing alert posts 🔴 and pings `@nuc-mods`; when it clears, a ✅
follows (`nuc: resolved: ...`, with how long it lasted) and pings no one. Each
alert is its own message, and one that stays firing is repeated every 12 hours.

Everything is on loopback. Without a Discord webhook (`homeserver.notify`),
Alertmanager and the relay do not run and Prometheus only evaluates the rules.

### The rules

There are two kinds. An **event** alert reports something that happened and
posts as soon as it can; its `for` is short or zero. A **threshold** alert
reports a condition that has lasted, so its `for` is long enough to ignore
normal busy spells. The values below are the deployed defaults, from the
`defaults` set in `rules.nix`.

| Alert | Kind | Fires when | Threshold | For |
|---|---|---|---|---|
| `TargetDown` | event | A scrape target (any job) does not answer; cAdvisor and comin are skipped while their own unit is failed (the notifier posts that) | none | 1 m |
| `UnitFailed` | event | A systemd unit is `failed` that the notifier does not watch | none | 0 s |
| `CominFetchFailed` | event | comin's last fetch of the repository failed | none | 30 m |
| `CominEvalFailed` | event | comin's last evaluation failed | none | 0 s |
| `CominBuildFailed` | event | comin's last build failed | none | 5 m |
| `TailnetDisconnected` | event | Tailscale is not running and logged in (skipped while `tailscaled` is failed) | none | 2 m |
| `GatewayUnreachable` | event | The LAN gateway does not answer ping | none | 2 m |
| `DnsFailing` | event | A DNS lookup through the nuc's resolver fails | none | 2 m |
| `DnsServerDown` | event | A DNS lookup against the nuc's Blocky or the Pi-hole on the NAS (network-attached storage) fails (`server` label) | none | 2 m |
| `DnsNasProbeMissing` | event | The NAS's DNS server has no probe result at all (rendered only when it is probed) | none | 15 m |
| `DnsServerNotBlocking` | event | A name on the blocklists comes back with a real address from `server` | none | 15 m |
| `DnsBlocklistEmpty` | event | A DNS blocklist group (`ads` or `threats`) has no names loaded, or is missing from Blocky's metrics ([dns.md](dns.md#the-alerts)) | none | 15 m |
| `DnsThreatBlocked` | event | A device looked up a name on a threat list (blocked) in the last 5 minutes | none | 0 s |
| `DnsNewClient` | event | A device appears in the DNS query log for the first time | none | 0 s |
| `DnsWatchFailing` | event | The timer that writes the query-log metrics fails, never ran, or its file is over 5 minutes old | none | 10 m |
| `OomKill` | event | The kernel killed a process for lack of memory in a named container | none | 0 s |
| `DiskFilling` | threshold | `/` (the one btrfs filesystem: `/srv`, `/nix` and Docker's data too) is fuller than | 85 % | 10 m |
| `HostMemoryLow` | threshold | Available memory is below | 10 % | 15 m |
| `HostCpuHigh` | threshold | CPU busy across all cores is above | 90 % | 15 m |
| `TemperatureHigh` | threshold | A sensor is within a margin of its own `crit` mark, or above a fixed limit if it has none | 5 degrees below `crit`; 85 degrees without one | 5 m |
| `ContainerCpuHigh` | threshold | One container uses more than this share of the whole host's CPU | 75 % | 15 m |
| `StackMemoryNearLimit` | threshold | A stack slice's memory is above this share of its own `memoryMax` | 90 % | 15 m |
| `StackMemoryStalled` | threshold | Processes in a stack slice wait for memory (pressure stall information, "some") this share of the time | 10 % | 10 m |
| `StackCpuStarved` | threshold | Processes in a stack slice are ready but wait for a core this share of the time | 25 % | 15 m |
| `DnsNxdomainBurst` | threshold | One device gets more than this many "no such name" answers a minute, and more than 5 times its own 7-day baseline | 10 a minute | 5 m |
| `DnsQueryLogLarge` | threshold | The DNS query log table with its indexes is larger than | 2 GB | 15 m |

Notes on a few of them:

- `UnitFailed` skips the units in `homeserver.notify.units`, so a failed
  watched unit posts once, from the notifier. The same goes for the symptoms of
  such a failure: `TargetDown` does not fire for cAdvisor, comin or the two
  blackbox jobs while their unit is failed, and `TailnetDisconnected` not
  while `tailscaled` is. It also skips the `notify-failure@` units: one of
  those fails when the notifier cannot reach Discord, and a second post would
  fail the same way and repeat every 12 hours.
- The DNS alerts (everything starting `Dns`, except `DnsFailing`) are the
  LAN DNS server's, [dns.md](dns.md#the-alerts) says what each means and what
  to do. They sit in the groups `homeserver-events` and `homeserver-dns`.
  `DnsFailing` still watches the nuc's own resolver, which is now the router.
- `GatewayUnreachable` is the cause when the LAN goes: while it fires,
  `DnsFailing` and `TailnetDisconnected` are held back, so the outage is one
  post.
- `OomKill` reads cAdvisor's kill counter over the last 5 minutes, for named
  containers only (the counter is also raised for each parent cgroup).
- The stack alerts read the stack's slice (`stack-<name>.slice`), not a single
  container, because limits are set per stack.
- The ICMP (Internet Control Message Protocol) probe needs the kernel setting
  `net.ipv4.ping_group_range` to allow unprivileged ping sockets, because the
  exporter has no `CAP_NET_RAW`. NixOS's default is right; an assertion fails
  the build if a host changes it.
- The gateway to ping is `homeserver.alerting.gateway`, default `192.168.1.1`.

### Timing

The VM test (`tests/alerting.nix`) measured, from the cause to the post:
`TargetDown` about 50 s after stopping an exporter, and `UnitFailed` about 15
to 20 s. Those figures are not the nuc's: the test evaluates every 5 s, uses a
`for` of 30 s for `TargetDown`, a 1 m `group_interval`, and (since #182) a
45 s grace for scrape gaps. On the nuc the
timings below are derived from the deployed configuration (15 s scrape and
evaluation, `group_wait` 10 s, `group_interval` 5 m), not measured there:

- `TargetDown`: roughly 1.5 to 2 minutes after the target stops, its 1 m `for`
  plus a scrape, an evaluation and the group wait.
- `UnitFailed`: roughly 10 to 40 s.
- A ✅ can arrive up to about 5 minutes after the condition clears (the
  `group_interval`), plus 2 minutes of `keep_firing_for` on every alert
  but `TargetDown`, event and threshold alike. That grace is
  `homeserver.alerting.gapGrace` (default `2m`, from `rules.nix`); only the
  VM test changes it. One missed scrape, such as a
  deploy restarting node-exporter, marks the series stale, and without
  `keep_firing_for` every standing alert would resolve and fire again (a ✅
  and, after the full `for`, a second 🔴 for a threshold alert). It also
  means `GatewayUnreachable` keeps holding back `DnsFailing` and
  `TailnetDisconnected` for 2 minutes after the gateway recovers.
- `OomKill`'s ✅ comes roughly 7 to 12 minutes after the kill: the 5 minute
  window, the 2 minutes, and up to the group interval.

### Tuning

Thresholds and durations are one set in one place. To change one, add an entry
in `hosts/nuc`, naming only what changes (it is merged over the defaults, so
other alerts and the other field keep theirs):

```nix
homeserver.alerting.thresholds.DiskFilling = {
  value = 90;
  for = "30m";
};
```

An event alert has no `value`; give it `{ for = "..."; }`. Merge as usual and
comin deploys it. The alert names in the table are the keys.

**Noise review.** The ticket asks for a week of watching for alerts that fire
on normal use. It is due 2026-11-05. An alert that fires on normal use is a bug
in its rule: raise its threshold or `for`, or change the rule.

### Stacks that are under-provisioned

`StackMemoryNearLimit` compares a slice with the `memoryMax` the stack itself
sets, so a stack with no limit never fires it, and a limit set too low does
(limits for stacks without one are #32). `StackMemoryStalled` and
`StackCpuStarved` catch a stack that is short of memory or CPU without hitting
a limit. Minecraft idles at about 84 % of its 18G limit (measured 2026-10-28),
under the 90 % line but not by much, so watch it during the noise week.

### What is not alerted

- **A failed watched unit, a failed deploy, a crashed container.** The
  notifier and the stack watcher already post them ([notifications
  runbook](notifications.md)); a second message would be a duplicate. The one
  accepted duplicate: node-exporter itself crashing gives the notifier's post
  and `TargetDown`.
- **The nuc being down.** Alerting runs on it. A check from outside is #112.
- **A failed notification.** The nuc cannot tell Discord that Discord is
  unreachable. The relay logs the failure to its journal, and Alertmanager
  retries. A second channel, a phone push, is #170.
- **Disk health (SMART, Self-Monitoring, Analysis and Reporting Technology):**
  #46. **Minecraft's tick rate and Java heap:** #168 (the player counts are in).

### Silencing

During planned work, silence an alert rather than letting it ping. In Grafana
(on the tailnet, [above](#opening-grafana)): Alerting, Silences, with the
Alertmanager data source selected; the same page lists the active alerts. Or
over SSH, on the nuc:

```bash
amtool --alertmanager.url=http://127.0.0.1:9093 silence add alertname=DiskFilling --duration 2h --comment 'resizing the disk'
amtool --alertmanager.url=http://127.0.0.1:9093 silence query
amtool --alertmanager.url=http://127.0.0.1:9093 silence expire <id>
```

A silenced alert posts nothing, firing or resolved, while the silence lasts.
Silences are kept in Alertmanager's state, not in the repo.

### Testing an alert by hand

Stop node-exporter for 2 minutes and watch the alerts channel:

```bash
ssh nuc 'sudo systemctl stop prometheus-node-exporter'
# wait 2 minutes, then
ssh nuc 'sudo systemctl start prometheus-node-exporter'
```

🔴 `nuc: Scrape target node is down (for 1m)` arrives roughly 1.5 to 2 minutes
after the stop, and ✅ `resolved` some minutes after the start (up to about 5
for the group interval, plus 2 of `keep_firing_for` on the other alerts;
`TargetDown` has none). Stopping it by hand does not fail
the unit, so the notifier stays quiet. The VM test does the same with all the
alerts and a deliberate break of each check.

### When an alert does not arrive

Follow the path from the end:

```bash
ssh nuc 'journalctl -u alert-relay -b --no-pager'      # each post and how long it took; failures with the exit status
ssh nuc 'journalctl -u alertmanager -b --no-pager'     # delivery to the relay
ssh nuc 'curl -s 127.0.0.1:9090/api/v1/alerts'         # what Prometheus has pending or firing
ssh nuc 'curl -s 127.0.0.1:9093/api/v2/alerts'         # what Alertmanager holds, and silenced or inhibited
```

If an alert is in Prometheus but not in Alertmanager, check the Alertmanager
unit. If it is in both and silenced or inhibited, that is the reason. The
relay answers Alertmanager with an error when a post fails, and Alertmanager
then retries.

If an alert arrives twice, look at the relay's times. Alertmanager gives each
notification as long as the group interval (5 minutes) and sends it again if
the relay has not answered by then, though the post may still go through.

Alertmanager and the relay have start limits: five failed starts in 15 minutes
(Alertmanager, which must also be ready within 100 s) or in 5 minutes (relay),
and then the unit stays `failed`, which the notifier posts. So a relay that
cannot start, for example with a missing secret, ends in a failure message
instead of restarting for ever.
