# Observability design (ticket 3.4, #25)

Date: 2026-10-27. Status: draft, for Alex's approval.

## Intent

Alex can open a dashboard from his own devices and see how the nuc and its
containers are doing: CPU (central processing unit), memory, disk, network,
temperatures, each container's use, and the game server's. Today the only
view is SSH (Secure Shell) and `systemctl`. This ticket gathers the metrics
and draws them. Alerting on them is the next ticket (#27); this one must
collect what #27's rules will need.

Decisions already made with Alex (2026-10-27, recorded on #25):

- Prometheus, node-exporter and cAdvisor are native NixOS services (ADR,
  Architecture Decision Record, 0006: no container gets the Docker socket).
- **Grafana is native too** (`services.grafana`), not a Compose stack, as
  the plan had it. The dashboards then keep working when Docker is what's
  broken, and its settings come from Nix and sops. ADR 0006 gets a note.
- Grafana listens on loopback and is published to the tailnet by
  **Tailscale Serve over plain HTTP** (Hypertext Transfer Protocol). HTTPS
  would put the tailnet's name in the public Certificate Transparency logs.
  Tailscale's WireGuard tunnel already encrypts the traffic. HTTPS on a
  friendly name is #163.
- comin's exporter is scraped too, for #27's rules.
- Alerting is out (#27); the backup-age metric is out (#26).

## Goals

1. **Metrics collected:** Prometheus scrapes node-exporter (the host),
   cAdvisor (containers), comin (deploys) and itself, every 15 seconds.
2. **Dashboards provisioned from the repo:** a host dashboard, a containers
   dashboard and a game-servers placeholder, plus the Prometheus data
   source. Nothing has to be clicked together in the UI (user interface),
   and a reinstall brings them back.
3. **Reachable from Alex's devices only:** `http://nuc:3000` over the
   tailnet, with a login. Unreachable from the LAN (local area network,
   expect a timeout) and from share recipients (friends, ADR 0011).
4. **Nothing else listens beyond loopback.** Prometheus, the exporters and
   Grafana bind to 127.0.0.1.

## Non-goals

- Alert rules and Alertmanager (#27). Backup age (#26). SMART, scrub and
  thermal alerts (#46), though the host dashboard shows temperatures
  node-exporter already reads.
- HTTPS and a friendly name (#163).
- Minecraft player counts. They need `mc-monitor`'s Prometheus exporter in
  a second container next to the server, which is a change to the
  Minecraft stack; a follow-up ticket (my call).
- Monitoring the NAS (network-attached storage).
- Long-term storage. Metrics older than the retention are gone.

## Anti-goals

- Any port beyond SSH and Grafana's reachable over the tailnet, or any new
  port reachable from the LAN.
- Grafana phoning home: update checks, usage reporting and Gravatar
  lookups off.
- A dashboard that depends on something edited in the UI. Provisioned
  dashboards are read-only in the UI; changes go through the repo.

## Constraints

- nixpkgs 26.05: Prometheus 3.12.0, node-exporter 1.11.1, cAdvisor 0.56.2,
  Grafana 13.0.11, Tailscale 1.98.10. The VM (virtual machine) tests'
  Headscale is 0.28.0.
- **Port 8080 is taken** on loopback by the `hello` stack. cAdvisor moves
  to **8081**. The others keep their usual ports: Prometheus 9090,
  node-exporter 9100, Grafana 3000, comin 4243.
- nixpkgs' Grafana module refuses to build without
  `settings.security.secret_key` set.
- `services.tailscale.serve` in nixpkgs configures Tailscale *Services*
  (named `svc:` virtual services, approved in the admin console), not the
  plain per-machine Serve this needs. So the module runs `tailscale serve`
  itself. Checked in Tailscale 1.98.10's source
  (`cmd/tailscale/cli/serve_v2.go`): only HTTPS asks the control server for
  the HTTPS capability, so plain HTTP works under Headscale and can be
  tested.
- Serve answers on the tailnet address inside `tailscaled`, so the nuc's
  firewall never sees those connections (the same as the peer API,
  `modules/base/tailscale.nix`). Unlike the peer API, **the tailnet policy
  does limit Serve** (`docs/runbooks/tailscale.md`). So the policy is what
  keeps share recipients off Grafana, and the real policy needs a change by
  Alex: `tcp:3000` added to the `autogroup:member` grant, and not to
  `autogroup:shared`'s.
- One btrfs filesystem holds `/`, `/srv`, `/nix` and Docker's data, so
  disk use is one figure.
- Secrets: Alex edits sops files himself. Claude never decrypts them.

## Design

### Where it lives

- `modules/observability/default.nix`: Prometheus, the exporters, Grafana,
  the Serve unit and the dashboards. Imported by `hosts/nuc/default.nix`.
- `modules/observability/dashboards/`: the hand-written game-servers
  dashboard. The two upstream dashboards are fetched (below).
- `hosts/nuc/observability.nix`: the sops secret for Grafana's admin
  password, from a new `secrets/observability.yaml`, key
  `grafana-admin-password`. Alex creates it. The module takes the file's
  path as an option, `homeserver.observability.grafanaAdminPasswordFile`,
  which the VM test points at a plain file.

### Prometheus

- `services.prometheus`, listening on 127.0.0.1:9090.
- Scrape interval 15 s. Jobs: `node` (127.0.0.1:9100), `cadvisor`
  (127.0.0.1:8081), `comin` (127.0.0.1:4243), `prometheus` (itself).
- Retention 30 days, capped at 10 GB (`--storage.tsdb.retention.size`),
  whichever comes first (my call: about 1 to 2 GB expected at this scale).
  Data in Prometheus's default `/var/lib/prometheus2`, on the root
  subvolume.

### node-exporter

- `services.prometheus.exporters.node`, 127.0.0.1:9100, firewall not
  opened.
- Collectors: the defaults plus `systemd`, which #27's failed-unit rule
  needs.

### cAdvisor

- `services.cadvisor`, 127.0.0.1:8081. It reads Docker's state as root, as
  a native service, which ADR 0006 allows.
- Keep its label and metric set modest: drop per-CPU (central processing
  unit) and per-disk-device detail if the series count is large. Measured
  during the build, not guessed.

### Grafana

- `services.grafana`, 127.0.0.1:3000.
- Admin user `admin`, password read with Grafana's file provider
  (`$__file{…}`) from the sops secret.
- `secret_key`: generated on the host at first start (32 random bytes into
  `/var/lib/grafana/secret_key`, mode 0400, owned by `grafana`) by a
  oneshot ordered before `grafana.service`, and read with `$__file{…}`.
  Grafana uses it only to encrypt secrets stored in its database, and this
  setup stores none (the Prometheus source has no credentials), so losing
  it on a reinstall costs nothing. That saves a second sops entry (my
  call).
- Off: sign-up, anonymous access, update checks, usage reporting,
  Gravatar. `cookie_secure` stays false (plain HTTP).
- Provisioning:
  - the Prometheus data source, uid `prometheus`, the default;
  - dashboards from a store path, in a folder named "nuc", not editable in
    the UI.

### Dashboards

- **Host:** "Node Exporter Full", grafana.com dashboard 1860.
- **Containers:** a cAdvisor dashboard from grafana.com, chosen during the
  build for working with cAdvisor 0.56's metric names (my call).
- Both are fetched from grafana.com's API at a **pinned revision**, with
  a fixed hash (`pkgs.fetchurl`), not copied into the repo: their licence
  terms are the authors', and pinning makes the build reproducible. A small
  derivation replaces the `${DS_PROMETHEUS}` placeholder that grafana.com
  exports carry with the uid `prometheus`.
- **Game servers:** hand-written, small. CPU, memory and network for the
  containers whose names start `minecraft`, from cAdvisor. Player counts
  come later (non-goals).

### Tailscale Serve

- A oneshot, `tailscale-serve-grafana.service`:
  - start: `tailscale serve --bg --http=3000 http://127.0.0.1:3000`;
  - stop: `tailscale serve --http=3000 off`, so removing the unit from Nix
    removes the Serve entry (Serve's configuration otherwise persists in
    `tailscaled`'s state).
  - `RemainAfterExit`, and both `wantedBy` and `after`
    `tailscaled-autoconnect.service`, so it runs once the nuc is logged in.
    The VM tests start autoconnect by hand, and this follows it.
- The address is `http://nuc:3000` (MagicDNS short name) from Alex's
  devices.

### Docs

- `docs/runbooks/observability.md`: what runs where, opening Grafana, the
  admin password, adding a dashboard, retention, and checking a scrape
  target.
- `docs/runbooks/tailscale.md`: `tcp:3000` in the `autogroup:member`
  grant, the reason, and that share recipients don't get it.
- ADR 0006: a note that Grafana moved to native, and why.
- `docs/PLAN.md` 3.4 as-built note, README runtime diagram and status.
- `docs/runbooks/secrets.md`: the new secret.

## Testing

### New flake check `observability` (VM test, nuc plus a LAN neighbour)

Runs the real host configuration with stacks removed (as other tests do),
a plain-file admin password, and one small container from a
`dockerTools` image (as `tests/announce.nix` does) for cAdvisor to see.

- Every Prometheus target is up (`/api/v1/targets`), comin's included.
  **Control:** stop node-exporter, and its target goes down.
- Prometheus has container metrics for the test container by name.
- Grafana: `/api/health` answers; logging in with the admin password
  works and a wrong one is refused; the data source's health check passes;
  the three dashboards are in the "nuc" folder; a query through Grafana
  (`node_load1`) returns data.
- Nothing new on the LAN: from the neighbour, the nuc's LAN address shows
  no port open among 3000, 8081, 9090, 9100 and 4243 (filtered).
  **Control:** a listener on the LAN address on another port, opened in
  the firewall, is seen, so the scan works.
- Every listener this ticket adds is on 127.0.0.1 (`ss -ltn`).

### `tests/tailscale.nix` changes

The full tailnet scan now expects 22, the peer API **and 3000**. Added:

- from the client, `http://nuc.tailnet:3000/api/health` answers through
  Serve;
- once the policy allows only `tcp:22`, port 3000 is filtered (the policy
  limits Serve, unlike the peer API), and allowing `tcp:3000` opens it
  again;
- stopping `tailscale-serve-grafana` removes the port from the scan.

### On the nuc after the merge

- Grafana opens at `http://nuc:3000` from Alex's workstation, once the
  policy has `tcp:3000`.
- The host dashboard shows data.
- From another LAN device, `nc -zv -w 5 <nuc LAN IP> 3000` times out.
- A friend's shared device can't reach 3000 (Alex checks, or a policy
  preview in the admin console).
- Prometheus's disk use after a day, extrapolated to 30.

## Left to the builder

- The exact cAdvisor dashboard, and whether to trim cAdvisor's metrics.
- The game-servers dashboard's layout.
- Prometheus's scrape timeouts and the like.

## Rollout

1. Alex adds `grafana-admin-password` to `secrets/observability.yaml`
   (`sops secrets/observability.yaml`) before the merge, or the deploy's
   activation fails on the missing secret.
2. Alex adds `tcp:3000` to the `autogroup:member` grant.
3. Merge; comin deploys.
4. The checks above.
