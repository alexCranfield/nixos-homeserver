# Observability: Prometheus and Grafana

Ticket 3.4 (#25). The nuc collects its own metrics and draws them in Grafana,
which Alex opens from his own devices over the tailnet. The configuration is
`modules/observability/default.nix`; the admin password's secret is wired in
`hosts/nuc/observability.nix`. Alert rules on these metrics are #27.

## What runs where

Everything is a native NixOS service, not a container (ADR, Architecture
Decision Record, 0006 and its note of 2026-10-27), so the metrics and the
dashboards keep working when Docker is what's broken.

| Service | Listens on | What it does |
|---|---|---|
| Prometheus | 127.0.0.1:9090 | Scrapes the four below every 15 s and stores the results |
| node-exporter | 127.0.0.1:9100 | The host: CPU, memory, disks, network, temperatures, and each systemd unit's state |
| cAdvisor | 127.0.0.1:9338 | Each container's CPU, memory and network (not its default 8080, which apps and the tests use) |
| comin's exporter | 127.0.0.1:4243 | Fetch, evaluation, build and deployment results |
| Grafana | 127.0.0.1:3000 | Dashboards; on the tailnet at `http://nuc:3000` through Tailscale Serve |

Nothing here is reachable from the LAN (local area network): all of it is
on loopback, and `tests/observability.nix` scans the LAN address to check.
The only way in from outside the nuc is Grafana, through Serve, from devices
the tailnet's access policy allows.

Failures of any of these units post to the alerts channel, like other
watched units ([notifications runbook](notifications.md)).

## Opening Grafana

From a device on the tailnet with access to `tcp:3000` (your own, under the
policy in the [tailscale runbook](tailscale.md); not share recipients), open
`http://nuc:3000`, or `http://nuc.<tailnet name>.ts.net:3000` where the short
name doesn't resolve. Log in as `admin`. The dashboards are in the `nuc`
folder:

- **Node Exporter Full**: the host (grafana.com dashboard 1860).
- **cadvisor dashboard**: containers, filtered by Compose project and
  container name (grafana.com dashboard 19792).
- **Game servers**: CPU, memory and network of the containers whose names
  start `minecraft`. Player counts are a follow-up ticket.

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
