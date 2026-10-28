# Alerting design (ticket 3.6, #27)

Date: 2026-10-28. Status: approved by Alex 2026-10-28.

## Intent

The nuc tells Alex when something needs his attention. Before this ticket he
had to open Grafana to find out. The metrics from #25 are already collected;
this ticket turns the ones that matter into alerts that post to the private
Discord alerts channel.

There are two kinds of alert (Alex, 2026-10-28):

- **Event alerts** report something that happened: a target that stopped
  answering, a failed deploy, the tailnet connection lost. They post **as
  soon as possible**. With Prometheus that means within about 30 seconds:
  one 15-second scrape, one rule evaluation, and a short grouping wait in
  Alertmanager. The tests measure the real figure.
- **Threshold alerts** report a condition that has lasted: temperature, disk
  filling, a container's CPU (central processing unit) or memory staying
  high. Each has a **duration it must hold for**, tunable per alert, so a
  brief spike posts nothing.

Each alert's threshold and duration are set in one place in the repo, so
Alex can tune them after the week of watching for noise that the ticket
asks for.

Decisions already made with Alex (2026-10-27 and 2026-10-28, on #27):

- **Alertmanager**, not Grafana alerting.
- The backup-age rule has moved to #26, which creates the backups.
- SMART (Self-Monitoring, Analysis and Reporting Technology) disk health
  stays in #46. This ticket covers temperature, which node-exporter
  already reads.
- **No duplicate posts.** The nuc already posts a failed watched unit
  (`modules/base/notify.nix`), a failed comin deployment, and a crashed
  container (the stack watcher, `modules/containers/stack-watch.sh`).
  Prometheus alerts only on what those can't see.

## Goals

1. **Alertmanager runs natively** and receives alerts from Prometheus. Both
   listen on loopback only.
2. **Alerts post to the private alerts channel** in the same style as the
   existing messages: a 🔴 title with the time in UTC (Coordinated
   Universal Time), pinging the role. A ✅ message follows when the
   problem clears; it does not ping.
3. **The rules below** each exist, have a tunable threshold and duration,
   and are proven to fire by a test that forces the condition.
4. **Alex can silence an alert** for a while, for example during planned
   work, without a deploy.

## Non-goals

- Backup age (#26) and SMART, btrfs scrub and disk-health alerts (#46).
- Reporting the nuc down while it is down. Alerting runs on the nuc, so it
  can't do this; a check from outside is #112.
- Push to phones (ntfy, #170) and routing through n8n (#171). Discord is
  the only receiver here, but the design must leave room for a second one.
- Setting limits on the stacks that have none (#32).
- What players feel inside Minecraft: the server falling behind its 20
  ticks per second, or Java's heap running short while the container
  looks fine. Both need the Minecraft exporter, so their alerts are added
  to #168 with the player counts.

## Anti-goals

- **Noise.** An alert that fires on normal use, such as Minecraft busy for
  a few minutes or a nightly job, is a bug in the rule. A reminder for an
  alert still firing comes every 12 hours at most, not every few minutes.
- **Two posts for one problem.** If one of the existing posters already
  reports something, Prometheus does not report it too.
- **Anything new reachable** from the LAN (local area network) or the
  tailnet. Alertmanager is reached through SSH (Secure Shell) or Grafana
  only.
- **The webhook URL anywhere readable.** It isn't put on a command line, in
  the Nix store, or in the journal (as in `notify.nix`).

## Constraints

- nixpkgs 26.05: Prometheus 3.12.0, Alertmanager 0.31.1, blackbox exporter
  0.28.0, node-exporter 1.11.1, Tailscale 1.98.10.
- One btrfs filesystem holds `/`, `/srv`, `/nix` and Docker's data, so
  there is **one disk figure**, and one disk rule on `/`, not separate ones
  for root and `/srv` as the ticket's text has it.
- The Discord webhook is in sops (`secrets/notify.yaml`, wired in
  `hosts/nuc/notify.nix`), and the role id too. Claude never decrypts them.
- Ports already used on loopback: 3000, 4243, 8080, 9090, 9100, 9338.
- Limits are per stack, on `stack-<name>.slice` (`resources.memoryMax`,
  `resources.cpuWeight`, `modules/containers/compose-stack.nix`), not per
  container. Minecraft's is 18G with a 12G Java heap inside it, and the
  pack uses about 14.5 GiB at idle (`stacks/minecraft/default.nix`). No
  stack has a CPU cap, only a weight.

## Design

### Where it lives

- `modules/observability/alerting.nix` (new): Alertmanager, the rules, the
  relay to Discord, and the extra exporters. Imported by
  `modules/observability/default.nix`.
- `modules/observability/rules.nix` (new): the rules, built from one
  attribute set of thresholds and durations, the tuning knobs.
- The Discord webhook and role are the ones `homeserver.notify` already
  has (`webhookFile`, `roleFile`). No new secret.

### Alertmanager

- `services.prometheus.alertmanager`, listening on **127.0.0.1:9093**.
  Prometheus sends to it (`alertmanagers` in its config).
- Routing: one route to one receiver for now, the Discord relay.
  - `group_by: ['...']`: every alert is its own group (my call). With
    coarser groups Alertmanager resends the whole group when one alert in
    it changes, and the relay would post the alerts that hadn't changed
    again, pinging each time.
  - `group_wait: 10s`, so event alerts post quickly.
  - `group_interval: 5m`.
  - `repeat_interval: 12h`.
  - `send_resolved: true`.
- **One inhibit rule** (my call): while `GatewayUnreachable` fires,
  `DnsFailing` and `TailnetDisconnected` are suppressed. Losing the LAN
  takes both with it, and one post says it all. Nothing else cascades:
  with Prometheus down nothing is evaluated, and with an exporter down its
  own alerts go quiet rather than fire, leaving `TargetDown`.
- The cluster listener (port 9094) is turned off; there is one
  Alertmanager.
- **Silences** are added in Grafana's alerting UI (user interface), through
  an Alertmanager data source provisioned next to Prometheus's. This also
  shows the active alerts. `amtool` on the nuc works too, over SSH.

### The relay to Discord (my call)

Alertmanager 0.31 has a built-in Discord receiver. It could do the job,
but it would post in its own format, could not read the role id from its
sops file, and would be a second, different way of posting to the
channel. Instead:

- A small local **webhook relay** on **127.0.0.1:9095**. It is a
  Python-standard-library HTTP (Hypertext Transfer Protocol) server under
  systemd, run as a dynamic user and given the webhook and role files as
  credentials, as `notify-failure@` is.
- For each alert in a notification it runs `homeserver-notify`
  (`homeserver.notify.sender`):
  - Firing: 🔴 title `nuc: <summary>` with the description as the body,
    pinging the role.
  - Resolved: ✅ title `nuc: resolved: <summary>`, not pinging.
- Everything the channel already does then applies: the UTC stamp, the
  2000-character cut, `@` escaped, and only the one role allowed to ping.
- It answers Alertmanager with an error if a post fails, so Alertmanager
  retries.
- It is a watched unit (`homeserver.notify.units`), so if it crashes the
  notifier posts that. A failure to reach Discord can't be reported through
  Discord at all, so there is no alert for failing notifications (my call):
  it would post only once posting works again. The relay logs each failed
  post to the journal, and #170 (ntfy) gives a second way out.
- It runs only on loopback, and the firewall stays closed.
- A second receiver later (ntfy, #170) is a second route in Alertmanager,
  not a change to the relay.

The cost: one more small program to keep. The built-in Discord receiver
stays the fallback if the relay proves troublesome.

### The rules

Each rule has a threshold and a duration (`for:`), from one attribute set
in `rules.nix`. The starting values are my calls, to be tuned after a week.

Event rules. "As soon as possible" means the `for:` is as short as the
condition allows: 0 where the metric is definite (a unit's state, a
failed evaluation), and a minute where one missed scrape is normal under
load. With the 15-second scrape and evaluation and the 10-second group
wait, a post comes within about 30 seconds of the condition, plus its
`for:`. The tests measure it.

| Alert | Condition | for |
|---|---|---|
| `TargetDown` | `up == 0`, for any scrape job | 1m |
| `UnitFailed` | `node_systemd_unit_state{state="failed"} == 1`, for units **not** in `homeserver.notify.units` (the list is generated from Nix into the rule's regex) | 0 |
| `CominFetchFailed`, `CominEvalFailed`, `CominBuildFailed` | `comin_last_{fetch,eval,build}_failed == 1` (the gap `notify.nix` leaves to this ticket) | 30m for fetch (a network blip), 0 for eval, 5m for build (comin reports a build cancelled by a newer commit as failed, then builds the newer one; the builder checks comin's exporter for how the metric behaves then) |
| `TailnetDisconnected` | the nuc not logged in to and connected to the tailnet (below) | 2m |
| `GatewayUnreachable` | the LAN's gateway not answering ping (blackbox exporter, ICMP) | 2m |
| `OomKill` | the kernel killed a process in a container or stack slice for running out of memory (cAdvisor's `container_oom_events_total` rising) | 0 |
| `DnsFailing` | a lookup through the nuc's resolver failing (blackbox exporter, DNS) | 2m |

Threshold rules (durations long, to ignore normal busy spells):

| Alert | Condition | for |
|---|---|---|
| `DiskFilling` | `/` above **85%** used | 10m |
| `HostMemoryLow` | available memory below **10%** | 15m |
| `HostCpuHigh` | CPU above **90%** busy across all cores | 15m |
| `TemperatureHigh` | a sensor within **5 °C of its `crit` mark** from the hardware, or at **85 °C** where the sensor has none (my call: `max` is often set low, on NVMe drives especially, and would fire under normal load; checked on the nuc before building) | 5m |
| `ContainerCpuHigh` | a container using above **75%** of the whole host's CPU (all cores) | 15m |
| `StackMemoryNearLimit` | a stack's slice using above **90%** of its own `memoryMax` (stacks without one are skipped) | 15m |
| `StackMemoryStalled` | a stack's processes stalled waiting for memory above **10%** of the time (pressure, "some") | 10m |
| `StackCpuStarved` | a stack's processes waiting for CPU above **25%** of the time (pressure, "some") | 15m |

**Under-provisioned stacks** (Alex, 2026-10-28: "if the minecraft
container is under-provisioned"). Use alone says little: Minecraft sits
near 80% of its limit at idle by design. The rules look at what a stack
lacks, against its own limit, and at the kernel's pressure figures, which
count the time a stack's processes spent waiting for memory or CPU.
`OomKill` (below, an event) says when the kernel has killed one for it.
The stack watcher already posts the crash that follows; the alert says
why. cAdvisor reports the slices, and (I believe) their pressure figures
in 0.56; the builder checks on the nuc, and falls back to node-exporter's
host-wide pressure if the per-slice figures are missing.

`ContainerCpuHigh` is a share of the whole host, not of one core: Minecraft with mods legitimately uses
several cores while players are on, and the alert is for a container
starving everything else.

Network alerts about the nuc's own connection can't reach Discord while
the connection is down. Alertmanager keeps retrying, so the alert arrives
once the connection is back, with the time it started in the body. Still
worth having: it tells Alex it happened and for how long. The tailnet case
is different. The internet can be up while Tailscale is down, which locks
friends out of the game, and that alert posts at once.

**Duplicates with the notifier.** Some metrics come from watched units:
node-exporter, cAdvisor, comin and tailscaled are all in
`homeserver.notify.units`, so a crash of one posts from the notifier. The
rules that would repeat it don't fire then (my call):

- `TargetDown` for the `cadvisor` and `comin` jobs, and
  `TailnetDisconnected`, are left out while node-exporter reports their
  unit `failed` (`unless` on `node_systemd_unit_state`).
- `TargetDown` for the `node` job can't be: node-exporter is what reports
  units. If node-exporter itself crashes, two posts come, the notifier's
  journal and Prometheus's "node target down". That case is accepted and
  documented. It is one exporter, and the second post says what has gone
  blind.
- A target that stops answering without its unit failing (a hang, or a
  clean stop) is posted by `TargetDown` alone.

Each rule carries `summary` and `description` annotations that say what is
wrong in plain words, with the value, for example "Disk / is 87% full
(threshold 85% for 10 min)".

### The extra metrics

- **Tailscale state**: a timer every 30 s runs `tailscale status --json`
  and writes `homeserver_tailscale_running` (1 when `BackendState` is
  `Running`) and `homeserver_tailscale_health_messages` (the count of
  health warnings) to node-exporter's textfile collector. That needs
  node-exporter's `textfile` collector and a directory for it. My call
  over scraping tailscaled's own metrics: they need the peer API's
  address, and the textfile is simpler to test.
- **Blackbox exporter** on 127.0.0.1:9115, with two probes: ICMP to the
  LAN gateway (192.168.1.1, the router; check it on the nuc) and a DNS
  lookup of a public name through the system resolver (Pi-hole today).
  The exporter needs `CAP_NET_RAW` for ICMP, which the nixpkgs module
  grants.

### Testing

- **`promtool check rules` and `promtool test rules`** in a new flake
  check. Each rule gets a unit test with synthetic series. It must fire
  when the condition holds for its duration, and stay quiet just short of
  it. This covers every rule and every threshold quickly, without a VM
  (virtual machine).
- **A VM test**, `tests/alerting.nix`, with the real pipeline (Prometheus,
  Alertmanager, the relay, `homeserver-notify`). The test sets short
  durations so it runs quickly. Discord is replaced by the stand-in
  webhook receiver the other notify tests use. It forces, and checks the
  post for:
  - `TargetDown`: stop node-exporter. The negative control: cAdvisor
    failed (killed) posts once, from the notifier.
  - The inhibit rule: `GatewayUnreachable` forced (the gateway address
    pointed at nothing) holds back `DnsFailing`.
  - Two alerts firing at once, one resolving: the other is not posted
    again.
  - `UnitFailed`: fail a unit not in the watched list. The negative
    control is a watched unit failing, which gives one post (the
    notifier's), not two.
  - `DiskFilling`: the threshold overridden low in the test.
  - `OomKill` and `StackMemoryNearLimit`: a test stack with a small
    `memoryMax` and a container that allocates past it.
  - `TailnetDisconnected`: `tailscale down`, in a variant with Headscale
    if that's cheap; otherwise the textfile with a stubbed status.
  - A resolved message once each condition clears, and no ping on it.
  - A silence added with `amtool`, which stops the next post.
  - The relay failing to post, which Alertmanager retries.
  - Nothing new listening beyond loopback (9093, 9095, 9115).
- The webhook URL never appears in the journal, as in the announce test.
- **Live, after deploy:** one alert forced on the nuc. Stopping
  node-exporter for two minutes is harmless. Alex sees the post and the
  resolved message in Discord.

### Docs

- A new section in `docs/runbooks/observability.md`: the rules and where
  they're tuned, silencing, and testing an alert by hand.
- `docs/runbooks/notifications.md`: who posts what, now four posters.
- The acceptance check of reviewing noise after a week stays on the
  ticket, as a follow-up to close it.

## Left to the builder

- The relay's code, within the bullets above, and its tests.
- Exact PromQL expressions, as long as the unit tests pin each rule's
  behaviour.
- How the VM test speeds things up (short `for:` values, a faster
  evaluation interval), so long as the deployed values are the ones in
  the tables.

## Checks to do on the nuc before building

The SSH agent had expired when this was written. Check with:

- `node_hwmon_temp_max_celsius` and `node_hwmon_temp_crit_celsius`: do the
  nuc's sensors report a max or crit mark, and at what value?
- The LAN gateway's address.
- `/var/lib/prometheus2`'s size a day after #25, which is also a #25
  follow-up.
