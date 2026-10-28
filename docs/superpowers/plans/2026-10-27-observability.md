# Observability (#25) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prometheus, node-exporter, cAdvisor and Grafana as native NixOS services on the nuc, Grafana reachable at `http://nuc:3000` over the tailnet through Tailscale Serve (plain HTTP), dashboards provisioned from the repo.

**Architecture:** One module, `modules/observability/default.nix`, imported by `hosts/nuc`. Everything listens on 127.0.0.1; a oneshot runs `tailscale serve` to publish Grafana's port on the tailnet address. A new VM (virtual machine) test, `observability`, proves collection and Grafana; `tests/tailscale.nix` proves the tailnet path and the policy.

**Tech Stack:** NixOS 26.05 modules (`services.prometheus`, `services.prometheus.exporters.node`, `services.cadvisor`, `services.grafana`), Tailscale 1.98.10 CLI, NixOS test driver (Python), sops-nix.

**Spec:** `docs/superpowers/specs/2026-10-27-observability-design.md`

## Global Constraints

- Ports, all on 127.0.0.1: Prometheus 9090, node-exporter 9100, **cAdvisor 8081** (8080 is the `hello` stack's), Grafana 3000, comin 4243 (already there). Tailnet: Serve on **tcp 3000**, plain HTTP.
- Scrape interval 15 s. Retention `30d` and `--storage.tsdb.retention.size=10GB`.
- node-exporter collectors: defaults plus `systemd`.
- Grafana: admin user `admin`; password via `$__file{<path>}` from option `homeserver.observability.grafanaAdminPasswordFile` (type `path`, no default); `secret_key` via `$__file{/var/lib/grafana/secret_key}`, generated on first start (32 random bytes, mode 0400, owner `grafana`). Off: `users.allow_sign_up`, `auth.anonymous.enabled`, `analytics.reporting_enabled`, `analytics.check_for_updates`, `analytics.check_for_plugin_updates`, `security.disable_gravatar = true`. `security.cookie_secure = false`.
- Data source uid `prometheus`, default. Dashboards in folder `nuc`, not editable in the UI (`allowUiUpdates = false`, `disableDeletion = true`).
- Dashboards: grafana.com 1860 (Node Exporter Full) **revision 45**; one cAdvisor dashboard (19792 rev 6 or 15798 rev 16, whichever renders container panels with cAdvisor 0.56's metrics; record the choice); fetched with `pkgs.fetchurl` from `https://grafana.com/api/dashboards/<id>/revisions/<rev>/download` with a fixed hash; `${DS_PROMETHEUS}` (and any other `${DS_*}` input) replaced by `prometheus`. Hand-written `modules/observability/dashboards/game-servers.json`.
- Serve unit name `tailscale-serve-grafana.service`; start `tailscale serve --bg --http=3000 http://127.0.0.1:3000`; stop `tailscale serve --http=3000 off`.
- sops: `secrets/observability.yaml`, key `grafana-admin-password`, **created by Alex**; Claude never decrypts or edits secrets.
- Repo conventions (CLAUDE.md): file header comments in the style of neighbouring modules; acronyms expanded once per document; commit subjects < 72 chars, **no Co-Authored-By or Claude-Session trailers**; no tailnet name, 100.x addresses, emails or friends' names in anything committed.
- Nix: source `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh` first. Local VM tests run only under TCG: `just vm-test-tcg <name>` (slow; no KVM on this workstation). CI runs the full set.

## Review Focus

1. **cAdvisor against Docker 29.** Docker 29 refuses API (application programming interface) clients older than 1.44; cAdvisor 0.56's Docker client may be older. Expected: containers appear with their names. Pinned by Task 1's "container metrics by name" assertion; if it fails, set `DOCKER_API_VERSION` for cAdvisor or record the gap.
2. **Grafana with its password file missing** (every other VM test that imports `hosts/nuc`, and a real host before Alex adds the secret). Expected: other tests still pass; on the host the deploy fails loudly rather than Grafana silently running without a password. Task 2 runs every check that imports `hosts/nuc`.
3. **Serve before the nuc is logged in** (boot ordering, VM tests that start autoconnect late). Expected: the Serve unit runs once autoconnect has, and retries rather than staying failed. Pinned in Task 3.
4. **Login through Serve** (Grafana's CSRF (cross-site request forgery) origin check behind a proxy with a different Host). Expected: a browser-style login with an `Origin` header works through `nuc.tailnet:3000`. Pinned in Task 3.
5. **Share recipients and Grafana.** Expected: a policy that grants only `tcp:22` leaves 3000 filtered. Pinned in Task 3.

---

### Task 1: Prometheus, exporters and the observability test

**Files:**
- Create: `modules/observability/default.nix`
- Modify: `hosts/nuc/default.nix` (import it)
- Create: `tests/observability.nix`, `tests/observability.py`
- Modify: `flake.nix` (check `observability`, with a comment line naming ticket 3.4 (#25) as neighbours do)

**Interfaces:**
- Produces: option namespace `homeserver.observability` (Task 2 adds to it); scrape job names `node`, `cadvisor`, `comin`, `prometheus` (#27 relies on them); the test file pair Tasks 2 and 3 extend; test container name `probe` from a `dockerTools` image (busybox, `sleep`), started by a oneshot as `tests/announce.nix` does.

- [ ] **Step 1: Write the test.** `tests/observability.nix`: one `nuc` node importing `../hosts/nuc` with `homeserver.stacks = lib.mkForce { }`, `services.tailscale.authKeyFile = lib.mkForce null`, `system.activationScripts.setupSecrets = lib.mkForce ""`, LAN on vlan 1 with a fixed address as `tests/tailscale.nix` does, the `probe` container; one `lan` node on vlan 1 with nmap and curl. Subtests in `tests/observability.py`:
  - `every scrape target is up`: `/api/v1/targets` has exactly jobs `{node, cadvisor, comin, prometheus}`, all `health == "up"` (wait up to 120 s).
  - `negative control: a stopped exporter shows down`: stop `prometheus-node-exporter`, wait for `node` to be `down`, start it, wait for `up`.
  - `cAdvisor sees the test container by name`: query `container_memory_usage_bytes{name="probe"}` returns ≥ 1 series.
  - `node-exporter reports systemd units`: `node_systemd_unit_state{name="sshd.service",state="active"} == 1`.
  - `everything listens on loopback`: `ss -ltnH` lines for ports 9090, 9100, 8081 all have local address `127.0.0.1`.
  - `nothing new on the LAN`: from `lan`, `nmap -Pn -p 3000,4243,8081,9090,9100 <LAN_IP>` shows none `open`. Control: on the nuc, a `python3 -m http.server 8999 --bind <LAN_IP>` plus `nft add rule inet nixos-fw input-allow tcp dport 8999 accept`; nmap sees 8999 `open`.
- [ ] **Step 2: Run it to see it fail.** `just vm-test-tcg observability` → fails at evaluation or the first subtest (no Prometheus).
- [ ] **Step 3: Implement** `modules/observability/default.nix`: `services.prometheus` (listenAddress `127.0.0.1`, port 9090, `globalConfig.scrape_interval = "15s"`, `retentionTime = "30d"`, `extraFlags` with the size cap, four `scrapeConfigs`), `services.prometheus.exporters.node` (listenAddress `127.0.0.1`, `enabledCollectors = [ "systemd" ]`), `services.cadvisor` (listenAddress `127.0.0.1`, port 8081). Import in `hosts/nuc/default.nix`; add the flake check.
- [ ] **Step 4: Run it to see it pass.** `just vm-test-tcg observability` → all subtests pass. Record cAdvisor's series count (`count({__name__=~"container_.*"})`) and, if it is above ~20 000, trim with cAdvisor's `--disable_metrics` and re-run.
- [ ] **Step 5: Format and evaluate.** `nix fmt` and `nix flake check --no-build` clean.
- [ ] **Step 6: Commit** `Add Prometheus, node-exporter and cAdvisor (#25)`.

### Task 2: Grafana, its secret and dashboards

**Prerequisite:** `secrets/observability.yaml` exists on the branch with key `grafana-admin-password` (Alex runs `sops secrets/observability.yaml` in the worktree; Claude commits the encrypted file). If it is missing, stop and ask; do not create it.

**Files:**
- Modify: `modules/observability/default.nix`
- Create: `modules/observability/dashboards/game-servers.json`
- Create: `hosts/nuc/observability.nix`; Modify: `hosts/nuc/default.nix` (import)
- Modify: `tests/observability.nix`, `tests/observability.py`
- Modify: any other `tests/*.nix` that imports `hosts/nuc` and breaks (Review Focus 2)

**Interfaces:**
- Consumes: Task 1's module and test.
- Produces: `homeserver.observability.grafanaAdminPasswordFile` (path); unit `grafana-secret-key.service` (oneshot, `before` and `requiredBy` `grafana.service`); Grafana on 127.0.0.1:3000; data source uid `prometheus`; dashboard folder `nuc` with three dashboards whose titles the test checks: `Node Exporter Full`, the chosen cAdvisor dashboard's title, `Game servers`.

- [ ] **Step 1: Extend the test.** In `tests/observability.nix` set the password option to `/run/observability-test/grafana-admin` filled by tmpfiles from a store file (as `tests/announce.nix` does for webhooks). Subtests:
  - `Grafana is healthy and requires a login`: `/api/health` 200; `/api/search` without credentials 401.
  - `the admin password works and a wrong one is refused`: basic auth `admin:<test password>` 200 on `/api/user`; `admin:wrong` 401.
  - `the secret key was generated once`: `/var/lib/grafana/secret_key` exists, mode `400`, owner `grafana`, 32 bytes or more; restarting `grafana.service` leaves its checksum unchanged.
  - `the data source is provisioned and healthy`: `/api/datasources/uid/prometheus/health` → `status == "OK"`.
  - `the three dashboards are in the nuc folder`: `/api/search?type=dash-db` titles ⊇ the three, each `folderTitle == "nuc"`.
  - `a query through Grafana returns data`: POST `/api/ds/query` for `node_load1` against uid `prometheus` returns ≥ 1 frame with values.
  - `Grafana does not phone home`: `/api/frontend/settings` (or the rendered `grafana.ini`) shows reporting and update checks off.
  - Extend `everything listens on loopback` with 3000.
- [ ] **Step 2: Run it to see it fail.** `just vm-test-tcg observability` → fails at the Grafana subtests.
- [ ] **Step 3: Implement** the option, `grafana-secret-key.service` (create only if absent; `umask 077`; `head -c 32 /dev/urandom | base64`), `services.grafana` per Global Constraints, provisioning of the data source and the dashboard provider (a store directory built by `pkgs.runCommand` from the two fetched files after placeholder substitution, plus `game-servers.json`), and the game-servers dashboard (CPU `rate(container_cpu_usage_seconds_total{name=~"minecraft.*"}[5m])`, memory `container_memory_working_set_bytes{name=~"minecraft.*"}`, network rx/tx rates; datasource uid `prometheus`). `hosts/nuc/observability.nix`: `sops.secrets.grafana-admin-password = { sopsFile = ../../secrets/observability.yaml; owner = "grafana"; };` and the option pointing at its path, with a header comment in the style of `hosts/nuc/notify.nix`.
- [ ] **Step 4: Run it to see it pass.** `just vm-test-tcg observability`.
- [ ] **Step 5: Other tests.** Grep `tests/*.nix` for `../hosts/nuc`. For each, decide: give it a password file as Step 1 does, or `services.grafana.enable = lib.mkForce false` where Grafana is irrelevant. Prefer a shared helper if three or more need the same lines. Confirm with `nix flake check --no-build`; the VM runs are CI's (Task 4).
- [ ] **Step 6: Format, evaluate, commit** `Add Grafana with provisioned dashboards (#25)`.

### Task 3: Tailscale Serve and the tailnet test

**Files:**
- Modify: `modules/observability/default.nix` (Serve unit)
- Modify: `tests/tailscale.nix`, `tests/tailscale.py`

**Interfaces:**
- Consumes: Grafana on 127.0.0.1:3000, its password option (Task 2).
- Produces: `tailscale-serve-grafana.service`.

- [ ] **Step 1: Extend the test.** In `tests/tailscale.nix` give the nuc a Grafana password file (as Task 2). In `tests/tailscale.py`:
  - The full-scan subtest's expected set becomes `{22, PEERAPI, 3000}` (update its title and comments: Serve answers inside `tailscaled` like the peer API, but the policy does limit it).
  - New subtest after the scan, `Grafana answers over the tailnet through Serve`: from the client, `curl -fsS http://nuc.tailnet:3000/api/health` succeeds; a login POST to `/login` with JSON `{"user":"admin","password":<test password>}` and header `Origin: http://nuc.tailnet:3000` returns 200 (Review Focus 4).
  - In the policy subtest: the policy allowing only `tcp:22` leaves 3000 `filtered` (add to the assertion's port list); then a policy allowing `tcp:22` and `tcp:3000` from `test@` opens 3000 again (wait up to 60 s), then restore the 22-only policy for the later subtests.
  - New subtest at the end, `stopping the Serve unit removes the port`: `systemctl stop tailscale-serve-grafana`, `tailscale serve status` no longer lists 3000, and `nmap -Pn -p 3000` from the client is not `open`.
- [ ] **Step 2: Run it to see it fail.** `just vm-test-tcg tailscale` → the scan finds no 3000.
- [ ] **Step 3: Implement** the oneshot: `Type = "oneshot"`, `RemainAfterExit = true`, `after` and `wantedBy` `tailscaled-autoconnect.service`, `after` `grafana.service`, `Restart = "on-failure"`, `RestartSec = 5`, `ExecStart`/`ExecStop` per Global Constraints, with a comment saying why not nixpkgs' `services.tailscale.serve` (it configures Tailscale Services, `svc:` names). Add 3000 to `modules/base/tailscale.nix`'s comment on what tailscaled answers by itself (Serve), and note the policy limits it.
- [ ] **Step 4: Run it to see it pass.** `just vm-test-tcg tailscale`; also re-run `observability` (the unit exists there without a login; it must not leave a failed unit that the test or `systemctl --failed` trips on; if it does, make the test tolerate it only by starting autoconnect, never by hiding the failure).
- [ ] **Step 5: Commit** `Publish Grafana on the tailnet with Tailscale Serve (#25)`.

### Task 4: Docs, follow-up, pull request

**Files:**
- Create: `docs/runbooks/observability.md`; Modify: `docs/runbooks/README.md` (index)
- Modify: `docs/runbooks/tailscale.md` (policy: `"ip": ["tcp:22", "tcp:3000", "tcp:25565"]` for `autogroup:member`; `autogroup:shared` unchanged; why), `docs/runbooks/secrets.md` (new secret), `docs/adr/0006-docker-vs-podman.md` (note: Grafana native, 2026-10-27, why), `docs/PLAN.md` (3.4 text: Grafana native and Serve over HTTP; as-built note after merge), `README.md` (runtime diagram and status)

- [ ] **Step 1: Write the runbook**: what runs where (ports table), opening Grafana, the admin password (where it lives, how to change it with sops), adding a dashboard (JSON in the repo; UI edits aren't saved), retention and disk use, checking a target (`curl -s 127.0.0.1:9090/api/v1/targets` over SSH), why plain HTTP (link #163), and what Serve's stop does.
- [ ] **Step 2: Update the other docs** listed above.
- [ ] **Step 3: File the follow-up issue** "Minecraft player counts on the game-servers dashboard" (mc-monitor exporter alongside the server), phase:4, area:games and area:observability, milestone Phase 4, Depends on #25.
- [ ] **Step 4: Full checks.** `just check` (or `nix flake check --no-build` plus the build of every check's derivation) clean; push; open the pull request with the spec's acceptance criteria as a checklist, the TCG test output, Alex's two rollout steps at the top, and the footer `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- [ ] **Step 5: Wait for CI's `check`.** Then a review subagent on the branch (it must not check out commits in Alex's clone); fix findings; re-review.
