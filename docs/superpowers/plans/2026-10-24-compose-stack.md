# Compose-stack module implementation plan (ticket 3.2, #23)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A NixOS module that turns a compose file plus a sops env file into
`stack-<name>.service`, with public ports declared in Nix and enforced by the
firewall, a flake check and a VM (virtual machine) test; crash alerts to
Discord; per-stack resource limits; and a `hello` stack live on the nuc.

**Architecture:** `modules/containers/compose-stack.nix` declares
`homeserver.stacks.<name>` and generates, per stack: files under
`/etc/stacks/<name>/` (the compose file unchanged, a generated override, the
`.env` link), a oneshot unit, a slice with the limits, a crash watcher, and
nftables rules in a table of its own that drop forwarded connections to
undeclared ports. A Python checker, run as a flake check, holds compose files
under `stacks/` to ADR (Architecture Decision Record) 0006's rules.

**Tech Stack:** NixOS 26.05, Docker 29.9.1 with its bundled Compose plugin,
nftables, sops-nix, Python 3 with PyYAML (checker), the NixOS test driver.

**Spec:** `docs/superpowers/specs/2026-10-24-compose-stack-design.md`. Read it
first; this plan does not repeat its reasons.

## Global Constraints

- Everything in `CLAUDE.md`: branch `ticket/23-compose-stack` (exists, holds
  the spec), squash-merged PR, evidence and negative controls in the PR,
  acronyms expanded at first use per document, commit subjects under 72
  characters, **no `Co-Authored-By` or session trailers**.
- Never in the repo, PRs or issues: NAS hostnames or paths, the tailnet name,
  Alex's email, the ULA (unique local address) prefix.
- Nix commands need the profile sourced, or run through `nix develop -c`.
  The flake sees git-tracked files only: `git add` new files before building.
- No KVM on the workstation: run VM tests as
  `nix develop -c just vm-test-tcg <name>` (TCG, Tiny Code Generator
  emulation; about 10 minutes for a three-machine test). Parallel runs need
  separate `git worktree add --detach` checkouts and their own
  `XDG_RUNTIME_DIR=$(mktemp -d -p /run/user/1000 nt.XXXX)`.
- Claude may not run `just deploy`; the nuc gets this through comin after
  merge.
- Public ports are IPv4 only; declared ports open on the public interface
  (`lan0` on the nuc) only.
- Stack unit depends on Docker with `Wants=`+`After=`, **never `Requires=`**.
- Crash alerts: first death of a container in the window posts without the
  role; the third death within the window (600 s, the notifier's
  `cooldown`) posts once with the role; others are counted.
- Data bind mounts: absolute paths under the stack's `dataDir` only.
- Match surrounding code: comment density and style of
  `modules/containers/docker.nix` and `modules/base/notify.nix`; `nix fmt`.

## Review Focus

1. **A compose change that only edits the env secret** (no compose edit)
   must still restart that stack: the restart trigger has to see the secret's
   content, not just its path. Task 2 pins it.
2. **A Docker restart in the middle of a stack's life** (deploy bumps Docker):
   unit stays active, containers keep IDs, watcher reconnects. Task 2 and
   Task 4 pin it.
3. **A port published as a range or in long syntax** (`target`/`published`/
   `host_ip`), and `${VAR}` interpolation in ports: the checker must not wave
   them through. Task 5 pins each.
4. **UDP public ports** (Palworld, Satisfactory): the firewall rules and the
   after-start listening check must handle `protocol = "udp"`, where `ss`
   shows `UNCONN`, not `LISTEN`. Task 3 pins it with a UDP declared port.
5. **A stack removed from the configuration**: its unit stops and runs
   `down`, and its firewall accept rule disappears. Task 2 pins the unit;
   Task 3 pins the rule.

---

## File structure

| File | Responsibility |
|---|---|
| `modules/containers/compose-stack.nix` (new) | options, files, unit, slice, override, firewall table, watcher |
| `modules/containers/stack-watch.sh` (new) | the watcher's loop, a `writeShellApplication` body |
| `modules/base/notify.nix` | expose the sender as read-only `homeserver.notify.sender` |
| `scripts/check_compose.py` (new) | the compose checker |
| `tests/compose-check/` (new) | checker fixtures, one bad file per rule plus good ones |
| `tests/compose-check.nix` (new) | flake check: runs the checker on `stacks/` and on the fixtures |
| `tests/compose-stack.nix`, `.py` (new) | the two-machine VM test |
| `stacks/hello/compose.yml`, `default.nix` (new) | the example stack |
| `hosts/nuc/default.nix` | import the module and `stacks/hello` |
| `flake.nix` | the two new checks |
| docs | see Task 6 |

---

### Task 1: Expose the notifier's sender

**Files:**
- Modify: `modules/base/notify.nix`

**Interfaces:**
- Produces: `config.homeserver.notify.sender`, read-only, the existing `send`
  package. Call shape unchanged:
  `homeserver-notify WEBHOOK_FILE ROLE_FILE|- ICON TITLE < body`.
  Also `homeserver.notify.icons` read-only attrset `{ up; down; wrong; }`.

- [ ] **Step 1:** Add the two read-only options (`readOnly = true;
  internal = false`), set them from `send` and `icon`. Doc comment says the
  stack watcher uses them.
- [ ] **Step 2:** `nix develop -c nix eval .#nixosConfigurations.nuc.config.homeserver.notify.sender.name`
  prints `"homeserver-notify"`. `nix develop -c nix build .#checks.x86_64-linux.toplevel` succeeds.
- [ ] **Step 3:** Commit `Expose the Discord sender for the stack watcher (#23)`.

### Task 2: The module: options, files, unit, slice, override

**Files:**
- Create: `modules/containers/compose-stack.nix`
- Create: `tests/compose-stack.nix`, `tests/compose-stack.py`
- Modify: `flake.nix` (check `compose-stack`), `hosts/nuc/default.nix` (import)

**Interfaces:**
- Produces, `homeserver.stacks.<name>` (attrsOf submodule):
  - `composeFile` (path), `services` (nonEmpty listOf str: the compose
    service names; the checker verifies they match the file),
  - `envSecret` (nullOr str: a key of `config.sops.secrets`),
  - `publicPorts` (listOf submodule `{ port: port; protocol: enum
    ["tcp" "udp"] = "tcp"; allowedSources: nullOr (listOf str) = null; }`),
  - `dataDir` (nullOr str), `autoStart` (bool, default true: `wantedBy
    multi-user.target`),
  - `resources.memoryMax` (nullOr str), `resources.cpuWeight` (nullOr int),
  - `after` (listOf str, default []).
- Produces `homeserver.publicInterface` (str, default `"lan0"`).
- Produces `config.homeserver.stacksManifest`, read-only: JSON-ready attrset
  `{ <name> = { composeFile; services; publicPorts; dataDir; }; }` for Task 5.
- Unit names: `stack-<name>.service`, `stack-<name>.slice`.
- Files: `/etc/stacks/<name>/compose.yml`, `/etc/stacks/<name>/override.yml`
  (`builtins.toJSON` of `{ services.<s> = { restart = "unless-stopped";
  cgroup_parent = "stack-<name>.slice"; }; }`; Compose reads JSON as YAML),
  `/etc/stacks/<name>/.env` (symlink to the secret's path, only if
  `envSecret` set).

- [ ] **Step 1: Write the VM test skeleton and the first failing subtests.**
  Two nodes on vlan 1: `nuc` imports `../hosts/nuc` (same overrides as
  `tests/docker.nix`: no tailscale key, no secrets activation, curl and
  iptables for the script, memory 2048, disk 4096,
  `homeserver.publicInterface = "eth1"`); `client` plain. Image: the `probe`
  busybox image from `tests/docker.nix`, loaded by a test-only oneshot
  `load-probe.service` that each stack lists in `after`. Stacks:
  - `fixture`: service `web`, ports `"0.0.0.0:8081:8080"` (declared tcp
    8081), `"8082:8080"` (no address, undeclared),
    `"0.0.0.0:8083:8080"` (undeclared), `"0.0.0.0:8084:8084/udp"` with a
    busybox `nc -lu` second service `udp` (declared udp 8084);
    `resources.memoryMax = "64M"`; `envSecret` = a test sops secret (reuse
    the pattern of `modules/dev/vm-secrets.nix`, or a plain file via
    `sops.secrets` override; builder's call) with `GREETING=one`.
  - `other`: service `web`, loopback only, no public ports.
  - `unbound`: `autoStart = false`, declares tcp 8090, publishes nothing.

  Subtests for this task:
  ```python
  with subtest("stacks start at boot and stay active"):
      nuc.wait_for_unit("stack-fixture.service"); nuc.wait_for_unit("stack-other.service")
  with subtest("files land in /etc/stacks, .env is not in the store"):
      nuc.succeed("test -f /etc/stacks/fixture/compose.yml -a -f /etc/stacks/fixture/override.yml")
      assert not nuc.succeed("readlink -f /etc/stacks/fixture/.env").startswith("/nix/store")
  with subtest("containers sit in the stack's slice, with restart unless-stopped"):
      # docker inspect: HostConfig.CgroupParent == "stack-fixture.slice", RestartPolicy.Name == "unless-stopped"
      # /proc/<pid>/cgroup of the container's process contains "stack-fixture.slice"
  with subtest("MemoryMax reaches the containers"):
      # docker exec fixture-web-1 sh -c 'head -c 200m /dev/zero | tail' exits 137,
      # and memory.events of stack-fixture.slice shows oom_kill >= 1
  with subtest("a daemon restart leaves stacks up"):
      # record container IDs and pids, systemctl restart docker,
      # stack-fixture still active, same IDs and pids
  with subtest("editing one stack restarts only that stack"):
      # switch to specialisation `changed` (fixture's compose gets an extra env var);
      # fixture's container ID changes, other's does not
  with subtest("an env-secret change alone restarts the stack"):
      # specialisation `newSecret`: only the secret content changes (GREETING=two);
      # fixture's container ID changes; `docker exec ... env` shows GREETING=two
  with subtest("removing a stack stops it and runs down"):
      # specialisation `withoutOther` drops homeserver.stacks.other;
      # `docker ps -a --filter label=com.docker.compose.project=other` is empty
  ```
- [ ] **Step 2:** Add the check to `flake.nix` (comment in the style of the
  others), `git add`, run `nix develop -c just vm-test-tcg compose-stack`.
  Expected: fails at evaluation (`homeserver.stacks` does not exist).
- [ ] **Step 3: Implement the module.** Unit per the spec's "The unit":
  `Type=oneshot`, `RemainAfterExit=yes`, `Wants`/`After` docker and
  `network-online.target` plus `after`; ExecStart
  `docker compose -p <name> --project-directory /etc/stacks/<name> -f compose.yml -f override.yml up -d --remove-orphans --wait`;
  ExecStop the same with `down`; `TimeoutStartSec=15min`; `restartTriggers`
  = compose file, override file, and for `envSecret` the sops secret's
  `restartUnits = [ "stack-<name>.service" ]` (sops-nix restarts it when the
  decrypted content changes); slice with `MemoryMax`/`CPUWeight` only when
  set; `dataDir` created with `systemd.tmpfiles` (`d <dir> 0750 root root`);
  `homeserver.notify.units` gets `stack-<name>`. Header comment in the style
  of `docker.nix`, including why not `Requires=`.
- [ ] **Step 4:** Run the test. Expected: these subtests pass. If `--wait`
  misbehaves for containers without healthchecks, or `restartUnits` does
  not fire inside the test, record what happened and adjust (that is the
  spec's builder's call), with the evidence in the PR.
- [ ] **Step 5:** Commit `Add the compose-stack module and its unit (#23)`.

### Task 3: Public ports: firewall table and after-start check

**Files:**
- Modify: `modules/containers/compose-stack.nix`, `tests/compose-stack.nix`, `tests/compose-stack.py`

**Interfaces:**
- Consumes: Task 2's options.
- Produces: `networking.nftables.tables.stack-ports` (family `inet`), log
  prefixes `"stack-port accept <port>/<proto> "` and
  `"stack-port drop "` (the port shows as `DPT=` in the log line);
  `stack-<name>.service` fails when a
  declared port is not bound on `0.0.0.0`.

- [ ] **Step 1: Failing subtests.**
  ```python
  with subtest("the client reaches the declared port over IPv4, and it is logged"):
      client.succeed(f"curl -sf --max-time 5 http://{NUC}:8081/hostname")
      nuc.wait_until_succeeds(f"journalctl -k --grep 'stack-port accept 8081/tcp' | grep -q 'SRC={CLIENT}'")
  with subtest("the declared UDP port gets through"):
      # client sends with `nc -u`, nuc's udp container log shows the payload
  with subtest("an undeclared port with no address binds loopback and times out"):
      nuc.succeed("ss -Hltn 'sport = :8082' | grep -q 127.0.0.1:8082")
      client.fail(f"curl -s --max-time 5 http://{NUC}:8082/")       # IPv4
      client.fail(f"curl -s --max-time 5 'http://[{NUC6}]:8082/'")  # IPv6
      # both exit 28 (timeout), not 7 (refused): assert the code
  with subtest("an undeclared 0.0.0.0 port is dropped by the firewall, and logged"):
      nuc.succeed("ss -Hltn 'sport = :8083' | grep -q 0.0.0.0:8083")
      client.fail(...)  # exit 28
      nuc.succeed("journalctl -k --grep 'stack-port drop' | grep -q 'DPT=8083'")
  with subtest("allowedSources keeps out everyone else"):
      # specialisation `restricted`: fixture's 8081 allowedSources = ["192.0.2.1/32"]; client times out
  with subtest("a declared port that does not bind fails the unit"):
      nuc.fail("systemctl start stack-unbound.service")
      nuc.succeed("systemctl is-failed stack-unbound.service")
  with subtest("a removed stack's port is closed"):
      # in `withoutOther`-style specialisation `withoutFixture`: no rule for 8081 in `nft list table inet stack-ports`
  with subtest("control: without default-network-opts, the no-address port binds everywhere"):
      # specialisation noNetworkDefault; stop stack-fixture (down removes its network); start;
      # ss shows 0.0.0.0:8082, and the client still times out (the firewall table holds)
  with subtest("control: without the stack-ports table, the undeclared 0.0.0.0 port is reachable"):
      # specialisation noStackFirewall: client reaches 8083
  ```
- [ ] **Step 2:** Run the test. Expected: fails at the first new subtest
  (8083 reachable, no log line).
- [ ] **Step 3: Implement.** Table per the spec's firewall section, chain on
  the forward hook at priority `filter - 10`, policy accept. Per declared
  port, two rules: one with `limit rate 10/minute burst 5 packets log prefix
  "stack-port accept …"` (no verdict), one with `counter accept`; matches are
  `ct state new ct status dnat iifname <publicInterface> meta l4proto <p>
  ct original proto-dst <port>` plus `ip saddr { … }` when `allowedSources`
  is set. Then for all other `ct state new ct status dnat`: a rate-limited
  `log prefix "stack-port drop "` rule and a `counter drop` rule. If nft
  prints the port other than as `DPT=` after DNAT, adjust the grep and
  record what it printed in the PR. Also add each declared port
  to `networking.firewall.interfaces.<publicInterface>.allowed{TCP,UDP}Ports`,
  with the comment that DNAT traffic skips the input chain. After-start
  check: `ExecStartPost` script, for each declared port, `ss -Hln{t,u}
  "sport = :<p>"` must show `0.0.0.0:<p>`, else exit 1 naming the port.
- [ ] **Step 4:** Run the test. Expected: all subtests pass, both controls
  pass (each control asserts the *broken* behaviour).
- [ ] **Step 5: Mutation runs**, each in its own worktree, each must fail at
  the named subtest; paste results in the PR: delete the drop rule (fails at
  "undeclared 0.0.0.0 port"); delete `default-network-opts` from
  `docker.nix` (fails at "binds loopback"); delete the ExecStartPost (fails
  at "does not bind fails the unit").
- [ ] **Step 6:** Commit `Enforce declared public ports in the firewall (#23)`.

### Task 4: Crash watcher

**Files:**
- Create: `modules/containers/stack-watch.sh`
- Modify: `modules/containers/compose-stack.nix`, `tests/compose-stack.nix`, `tests/compose-stack.py`

**Interfaces:**
- Consumes: `homeserver.notify.{sender,icons,webhookFile,roleFile,cooldown}`.
- Produces: `stack-<name>-watch.service`, only when
  `homeserver.notify.webhookFile != null`. Script args:
  `stack-watch PROJECT WEBHOOK_FILE ROLE_FILE|- COOLDOWN HOST`.
  State: `$STATE_DIRECTORY/<container>` holding death timestamps.

- [ ] **Step 1: Failing subtests.** In the test, point
  `homeserver.notify.webhookFile` at a file holding the URL of a receiver
  like `tests/notify.nix`'s (copy it; it writes each POST to
  `/tmp/shared/webhook/NNN.json`), and `roleFile` at a file with a numeric id.
  ```python
  with subtest("a crash restarts the container and posts quietly"):
      # docker kill --signal KILL fixture-web-1; wait for it running again (same name, RestartCount 1)
      # one new message: title contains "fixture-web-1" and "exit 137"; content has no "<@&"
  with subtest("a third crash within the window pings, once"):
      # two more kills; exactly one more message, with "<@&<role>>" and "3 times"
      # a fourth kill: no new message
  with subtest("stopping a stack is not a crash"):
      # systemctl stop stack-other; start it again; no new message
  with subtest("the watcher survives a daemon restart"):
      # systemctl restart docker; wait for stack-other-watch active again;
      # kill other-web-1 (new container, fresh window): one quiet message
  ```
- [ ] **Step 2:** Run. Expected: fails at the first new subtest (no message).
- [ ] **Step 3: Implement.** Unit: `BindsTo=` and `After=` `stack-<name>.service`,
  `Wants`/`After` docker, `Restart=always`, `RestartSec=5`, runs as root
  (reads the secrets directly, like `notify-online`), `StateDirectory=
  stack-watch/<name>`, `wantedBy` the stack unit. Script loop:
  `docker events --format '{{json .}}' --filter type=container --filter
  event=die --filter label=com.docker.compose.project=<name>`; per event,
  read `.Actor.Attributes.name` and `.exitCode` with `jq`; if `systemctl
  is-active stack-<name>` is not `active`, skip; prune timestamps older than
  COOLDOWN; append now; count n: n = 1 posts with role `-`, n = 3 posts with
  the role file, otherwise nothing. Title:
  `"<host>: <container> crashed (exit <code>)"`, with
  `", <n> times in <cooldown/60> min"` when n = 3; icon `wrong`; body: the
  container's last 20 journal lines (`journalctl CONTAINER_NAME=<c> -n 20`).
- [ ] **Step 4:** Run. Expected: pass.
- [ ] **Step 5: Mutation run:** make the n = 3 branch post with `-`; must fail
  at "pings, once". Paste in the PR.
- [ ] **Step 6:** Commit `Alert Discord when a stack's container crashes (#23)`.

### Task 5: The compose checker

**Files:**
- Create: `scripts/check_compose.py`, `tests/compose-check.nix`,
  `tests/compose-check/` fixtures
- Modify: `flake.nix` (check `compose-check`)

**Interfaces:**
- Consumes: `config.homeserver.stacksManifest` of the nuc, as JSON.
- Produces: `check_compose.py MANIFEST.json STACKS_DIR` exits 0 or 1; each
  problem on its own line as `<file>: <rule>: <detail>`, rule ids
  `no-address`, `undeclared-public`, `host-binding-opt`, `host-network`,
  `docker-socket`, `bind-outside-data`, `declared-unused`, `services-mismatch`,
  `interpolated-port`, `unlisted-file`.

- [ ] **Step 1: Fixtures.** `tests/compose-check/manifest.json` declaring
  stacks `good` (tcp 25565, udp 8211-8212, dataDir `/srv/data/good`) and one
  stack per rule; `tests/compose-check/<rule>/compose.yml` each breaking
  exactly one rule, covering: short `"25565:25565"`, `"25565"`, a range
  `"8000-8001:8000-8001"`, long syntax without `host_ip`, `"0.0.0.0:9999:9999"`
  undeclared, a `driver_opts` host binding, `network_mode: host`,
  `/var/run/docker.sock` short and long volume syntax, `./data:/data`,
  `/srv/other:/x`, a declared-but-unpublished port, `${PORT}:25565`, a
  service not in `services`, and a compose file under no declared stack.
  `good/compose.yml` uses long and short syntax, a UDP range and a named
  volume, and must pass.
- [ ] **Step 2: The check derivation** `tests/compose-check.nix`: runs the
  checker on `good` (expects 0), on each rule fixture (expects 1 and the
  rule id in the output: an in-check negative control per rule), then on the
  real `stacks/` with the nuc's manifest (expects 0). Add to `flake.nix`,
  `git add`, run `nix develop -c nix build .#checks.x86_64-linux.compose-check`.
  Expected: fails (no checker).
- [ ] **Step 3: Implement `check_compose.py`.** PyYAML; normalise short and
  long port syntax to `(host_ip, published range, protocol)`; empty
  `host_ip` = no address; `0.0.0.0`, `::` and `[::]` = public. Volumes:
  short `src:dst[:mode]` and long `type: bind, source:`.
- [ ] **Step 4:** Run the build. Expected: success; output lists each fixture
  and its rule.
- [ ] **Step 5: Mutation runs** in the PR: comment out one rule's code at a
  time for `no-address` and `undeclared-public`; the build must fail on that
  fixture. And `just check` must turn red when `stacks/hello/compose.yml`
  gets `"8080:80"`.
- [ ] **Step 6:** Commit `Check compose files under stacks against ADR 0006 (#23)`.

### Task 6: The hello stack, docs, and the deploy

**Files:**
- Create: `stacks/hello/compose.yml`, `stacks/hello/default.nix`,
  `docs/runbooks/stacks.md`
- Modify: `hosts/nuc/default.nix`, `docs/runbooks/docker.md`,
  `docs/runbooks/README.md`, `docs/adr/0006-*.md`, `docs/PLAN.md`,
  `README.md`, `docs/q-and-a/security.md`

- [ ] **Step 1: hello.** One service `web` from a small web server image
  with a pinned version tag (builder picks, e.g. `traefik/whoami` or
  `nginx:<x.y>-alpine`), ports `"127.0.0.1:8080:80"`, no secret, no public
  port, `resources.memoryMax = "64M"`. `just check` passes (toplevel builds,
  compose-check covers hello).
- [ ] **Step 2: Docs.** `stacks.md` (adding a stack, declaring a port, what
  the checker rejects and why, reading `journalctl -k --grep stack-port`,
  restarting/removing a stack, crash alerts and the ping rule, the hairpin
  limitation, the Docker-restart behaviour); `docker.md` points to it and
  drops "nothing runs in Docker"; ADR 0006 dated Consequences note (slice
  correction; the firewall now enforces declared ports, since #22's forward
  filter); PLAN 3.2 as-built; README layout rows, test count, Practices
  wording if it changes; Q&A in `security.md`: Alex's two questions from
  2026-10-24, verbatim ("So Lan with port forwarding, is that more secure
  than a public port?" and "Could we IP whitelist the server as a way to
  improve security? Or is that going to cause more headaches than its
  worth?"), answers in `<details>`.
- [ ] **Step 3:** Full `nix develop -c just check` green; all VM tests that
  import `hosts/nuc` still pass in CI.
- [ ] **Step 4:** Commit, push, open the PR with the acceptance criteria as a
  checklist and the evidence (test output, mutation runs). Review subagent
  before Alex's review, and again after fixes.
- [ ] **Step 5: After Alex merges** (his approval only): wait for comin to
  deploy, then on the nuc: `systemctl status stack-hello` active,
  `curl -s 127.0.0.1:8080` answers, `ss -Hltn` shows 8080 on 127.0.0.1 only,
  `nft list table inet stack-ports` present, `systemd-cgls` shows the
  container under `stack-hello.slice`. Record in `stacks.md`'s record table,
  close #23 with the verification comment, file the image-update follow-up
  issue, update memory.
