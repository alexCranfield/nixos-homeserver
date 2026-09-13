# Home Server Build Plan: NixOS on ASRock NUC BOX-358H

## Context

Alex is standing up a new home server on an ASRock Industrial NUC BOX-358H (Intel Core Ultra X7 358H "Panther Lake", 4P+8E+4LPE cores, Arc B390 Xe3 iGPU and NPU (Neural Processing Unit), 96 GB DDR5, 1 TB NVMe, dual Intel 2.5GbE, second M.2 slot free). Workloads: dockerised game servers (Minecraft, Palworld, Satisfactory, others), local LLMs, and a dev environment for Shopify admin scripting.

The previous NAS (network-attached storage) project, `alexCranfield/ansible-nas`, ran OMV (OpenMediaVault) on a Raspberry Pi. It used Ansible, pixi, Ansible Vault, unattended-upgrades, fail2ban, SSH via `~/.ssh/config` host `nas` (user `<nas-user>`, `<nas-host>`). This project is the "step further": the whole OS is declared in a Nix flake, installs and updates are automated, and the repo doubles as public CV evidence of a GitOps workflow.

Every ticket below is filed as a GitHub Issue in this repo, grouped by phase milestone. This file is the narrative version; the issues are the source of truth for status.

## Decisions (locked with user)

| Area | Decision | Why |
|---|---|---|
| OS | NixOS 26.05 "Yarara" (stable, EOL 2026-12-31; bump to 26.11 when released) | Fully declarative, one-command reinstall |
| Kernel | `linuxPackages_latest`, not default LTS | Panther Lake Xe3 iGPU and NIC support need a current kernel |
| Nix itself | Workstation keeps Determinate Nix; server takes the NixOS default. Match inputs, not versions (ADR 0007) | Locked inputs give identical derivations either side; no third-party flake on an unattended machine |
| Install | `nixos-anywhere` + `disko` from the NixOS live USB | Reproducible partitioning, no manual installer clicks |
| Containers | Docker + Compose stacks wrapped in systemd units from NixOS; K3s as final stretch phase | Game server docs assume compose; K8s later once base is stable |
| Deploy | Public repo. GitHub-hosted Actions validate/build on PR. Server pulls `main` with **comin** and rebuilds itself (~60 s after push) | CV evidence, no self-hosted runner exposure on a public repo |
| Secrets | `sops-nix` with an `age` key per host (replaces Ansible Vault) | Safe to commit encrypted secrets to a public repo |
| Remote access | Tailscale for SSH/admin/LLM UIs; router port forwards only for game ports | Nothing admin-facing on the WAN, no fail2ban needed |
| LLM | Ollama + Open WebUI on CPU (96 GB RAM fits 70B-class quants); Intel iGPU acceleration as a later trial ticket | Intel Level Zero on Panther Lake still has open init-crash bugs |
| Backups | `restic` nightly to <nas-host> over SFTP (SSH File Transfer Protocol); NixOS `services.restic` | Reuses existing NAS |
| Tickets | GitHub Issues + milestones per phase in this repo | Trackable, closable, visible |

## Target architecture

```
GitHub: alexCranfield/nixos-homeserver (public)
  ├─ PR → Actions: nix flake check, build toplevel, sops sanity, lint
  └─ main ──(comin polls)──▶ NUC: nixos-rebuild switch (auto, with rollback on boot failure)

NUC (NixOS 26.05, hostname: nuc)
  ├─ base: users, sshd (keys only), firewall, tailscale, restic, prometheus exporters
  ├─ docker + compose stacks (each a systemd unit, files owned by NixOS):
  │    games/minecraft  games/palworld  games/satisfactory
  │    ai/ollama + open-webui        obs/grafana + prometheus + cadvisor
  ├─ /srv/data/<stack>   persistent volumes (btrfs subvolume, snapshotted + restic'd)
  └─ dev: home-manager user, direnv + flake dev shells (Shopify tooling), VS Code Remote over Tailscale

Backups: NUC ──restic/SFTP──▶ <nas-host>:<nas-backup-path>
Admin:   WSL/laptop ──Tailscale──▶ nuc (SSH, Grafana, Open WebUI)
Friends: WAN ──router port-forward──▶ game ports only
```

## Repo layout (`nixos-homeserver`)

```
flake.nix / flake.lock
hosts/nuc/{default.nix, hardware-configuration.nix, disko.nix}
modules/
  base/        users, ssh, firewall, nix settings, gc, kernel
  network/     tailscale, static addressing
  containers/  docker, compose-stack.nix (reusable module: one systemd unit per stack)
  services/    restic, monitoring, comin
stacks/        docker-compose.yml + .env.sops per stack (games/, ai/, obs/)
secrets/       *.yaml encrypted with sops (age)
.sops.yaml
dev/           dev shells (shopify, python, node)
.github/workflows/  ci.yml, update-flake-lock.yml
docs/          PLAN.md (this plan), adr/*.md, runbooks/*.md
```

Reused from the NAS project: pixi-style task runner idea becomes `just`/`nix run` targets; the `security-pkgs` role's intent (auto updates) becomes comin + `update-flake-lock`; Vaulted `notification_email_address` pattern becomes a sops secret.

## Phased tickets

Ticket bodies with tasks and acceptance criteria are in `scripts/tickets.py`; `scripts/file_issues.py` files them as issues. Each ticket becomes one GitHub Issue: title, goal, task checklist, acceptance criteria, depends-on. Milestone = phase. Labels: `phase:N`, `area:{nix,ci,install,network,containers,games,llm,dev,backup,security,docs}`, `stretch`.

### Phase 0: Workstation and repo foundations (no hardware needed)
- **0.1** Install Nix on WSL (Determinate installer, flakes enabled) and `direnv`. AC (acceptance criteria): `nix flake --version` works, `nix run nixpkgs#hello` works.
- **0.2** Repo hygiene: `.gitignore`, `.editorconfig`, issue and PR templates, branch protection prep. (Repo, README, GPL-3.0 and this plan already exist.) AC: templates offered when opening an issue.
- **0.3** Flake skeleton: `flake.nix` with nixpkgs 26.05 input, `nixosConfigurations.nuc` stub, `formatter`, `checks`. AC: `nix flake check` passes locally.
- **0.4** CI workflow `ci.yml`: on PR/push run `nix flake check`, `nix build .#nixosConfigurations.nuc.config.system.build.toplevel`, `nix fmt -- --ci`. Use `DeterminateSystems/nix-installer-action` + `magic-nix-cache-action`. AC: green check on a PR.
- **0.5** Secrets bootstrap: generate `age` keys (workstation + placeholder host key), `.sops.yaml`, `sops-nix` input, one test secret decrypted in a NixOS VM build. AC: `sops -d secrets/test.yaml` works; a public-repo secret scan shows only ciphertext.
- **0.6** ADRs (Architecture Decision Records): review 0001-0005 and 0007, which already exist, then write `0006-docker-vs-podman.md` and an index. AC: each ADR states context, decision, consequences; index lists all of them.
- **0.7** `just`/`nix run` task targets: `fmt`, `check`, `build`, `deploy` (manual `nixos-rebuild --target-host` for emergencies), `vm` (build a QEMU VM of the config). AC: `just vm` boots the config locally.

### Phase 1: Bare-metal install and base OS
- **1.1** Hardware prep: seat RAM/NVMe, BIOS: restore power on AC loss, boot order USB, disable Secure Boot (lanzaboote is a stretch), enable VT-x/VT-d. Record BIOS version. AC: checklist in `docs/runbooks/hardware.md`.
- **1.2** `disko.nix`: GPT (GUID Partition Table), 1 GB ESP (EFI System Partition), btrfs root with subvolumes `@root @nix @home @srv @docker @snapshots`, 16 GB swapfile (or zram). Leave second M.2 slot documented for future data disk. AC: `nix build .#nixosConfigurations.nuc.config.system.build.diskoScript` succeeds.
- **1.3** Base module (shared policy only; hostname and stateVersion live in `hosts/nuc/`): user `ops` (wheel, ssh key only, no password sudo prompt kept), `sshd` keys-only + no root login, `nix.settings` (flakes, trusted users, auto-optimise), weekly GC (garbage collection), `linuxPackages_latest`, `hardware.cpu.intel.updateMicrocode`, timezone/locale. AC: VM boots, SSH login as `ops` works.
- **1.4** Network: DHCP reservation on router for `eno1` (record MAC), hostname `nuc.home.arpa`, second NIC unused/disabled. Firewall default deny, allow SSH only from Tailscale interface after 1.5. AC: `ping nuc.home.arpa` from LAN.
- **1.5** Tailscale module: `services.tailscale` with auth key via sops, MagicDNS, SSH over tailnet. AC: `ssh ops@nuc` from WSL works over Tailscale with LAN cable unplugged from the workstation.
- **1.6** Install: boot NixOS 26.05 live USB, run `nixos-anywhere --flake .#nuc --target-host root@<live-ip>` from WSL. Generate and commit `hardware-configuration.nix`. Run `nixos-generate-config --show-hardware-config` to verify. AC: reboots into NixOS, `nixos-version` shows 26.05, `lspci` shows Xe3 iGPU and both NICs, `dmesg` clean of NIC/GPU errors.
- **1.7** Host age key: copy `/etc/ssh/ssh_host_ed25519_key` derived age pubkey into `.sops.yaml`, re-encrypt secrets, confirm sops-nix decrypts on host. AC: `cat /run/secrets/test` works on nuc.
- **1.8** Smoke tests + runbook: `docs/runbooks/reinstall.md` covering 1.1 to 1.7 so a wipe-and-reinstall is a documented under-one-hour procedure. AC: runbook reviewed.

### Phase 2: GitOps, updates, rollback
- **2.1** `comin` module: poll `main` of the public repo every 60 s, deploy on new commit. Optionally require signed commits (comin supports GPG-verified commits). AC: push a change to `motd`, see it on host within 2 min without SSH.
- **2.2** `update-flake-lock.yml`: weekly Action opens a PR bumping `flake.lock`; CI builds it. Enable auto-merge on green for nixpkgs-only bumps (decide after first month). AC: first automated PR merged and deployed via comin.
- **2.3** Safe update policy: `system.autoUpgrade` disabled (comin owns it), `boot.loader.systemd-boot.configurationLimit = 10`, kernel-change reboots scheduled in a maintenance window (e.g. 04:00 Tue) via a timer; game servers get a pre-reboot RCON (remote console) warning hook (Phase 4 wires this). AC: documented in `docs/runbooks/updates.md`.
- **2.4** Rollback drill: deploy a deliberately broken service, confirm comin/systemd fails safely, roll back via bootloader generation and via `git revert`. AC: both paths documented and tested.
- **2.5** Notifications: comin/systemd failure → ntfy or Discord webhook (secret in sops). AC: a forced failure produces a notification.
- **2.6** README badges + architecture diagram (Mermaid) for the CV angle. AC: README explains the pipeline in one screen.

### Phase 3: Container platform, observability, backups
- **3.1** Docker module: `virtualisation.docker` (or podman with docker compat, decide in ADR 0006), data-root on `@docker` subvolume, log rotation, `docker system prune` timer. AC: `docker run hello-world` as `ops`.
- **3.2** Reusable `compose-stack` NixOS module: input = stack name + compose file path + sops env file; output = systemd unit that `docker compose up -d` on activation and `down` on stop, restarts on file change, ordered after `docker.service` and network-online. AC: a `hello` stack deploys via comin and is a systemd service.
- **3.3** Data layout: `/srv/data/<stack>` btrfs subvolumes, ownership conventions, `docs/runbooks/data-layout.md`. AC: documented, first stack uses it.
- **3.4** Observability stack: Prometheus + node-exporter (NixOS module) + cAdvisor + Grafana (compose), Grafana behind Tailscale only. Dashboards: host, containers, per-game-server. AC: Grafana reachable at `http://nuc:3000` over Tailscale, host dashboard populated.
- **3.5** Restic backups: `services.restic.backups.nas` to `sftp:<nas-user>@<nas-host>:<nas-backup-path>`, nightly, btrfs snapshot before backup, retention 7d/4w/6m, `restic check` weekly, failure notification. Add `nas` host key + restic password to sops. AC: restore test of one file into `/tmp` succeeds.
- **3.6** Alerting: Grafana or Prometheus alert rules for disk >85%, backup age >36h, unit failed. AC: one test alert delivered.

### Phase 4: Game servers
- **4.1** Minecraft: `itzg/minecraft-server` compose stack, world on `/srv/data/minecraft`, RCON, memory limit, EULA via env, pre-backup `save-off/save-all` hook. Router forward TCP 25565. AC: a friend connects from outside the LAN.
- **4.2** Palworld: `thijsvanloef/palworld-server-docker`, RCON, scheduled restarts, memory cap (Palworld leaks). Forward UDP 8211. AC: external connection.
- **4.3** Satisfactory: `wolveix/satisfactory-server`, forward TCP/UDP 7777. AC: external connection.
- **4.4** Game ops runbook + maintenance-window hooks: RCON "server restarting in 5 min" broadcast tied into the Phase 2.3 reboot timer; per-game backup hooks wired into 3.5. AC: reboot timer fires the broadcast in a test.
- **4.5** Resource policy: systemd `MemoryMax`/`CPUWeight` per stack so LLM jobs never starve game servers (LLM stacks get lower CPUWeight). AC: documented weights, `systemd-cgtop` shows enforcement.
- **4.6** Template for adding a new game server (copy stack dir, add port, add backup path). AC: `docs/runbooks/new-game-server.md`.

### Phase 5: Local LLMs
- **5.1** Ollama stack (CPU), models on `/srv/data/ollama`, `OLLAMA_NUM_PARALLEL`/threads tuned for 4P+8E, keep-alive policy. AC: `ollama run llama3.x` responds; API reachable over Tailscale.
- **5.2** Open WebUI stack behind Tailscale, auth enabled, secret key in sops. AC: chat works from phone on tailnet.
- **5.3** Model storage budget: 1 TB NVMe is shared; set a model quota (e.g. 200 GB) and document candidates for the second M.2 slot. AC: alert on `/srv/data/ollama` > quota.
- **5.4** Intel iGPU trial (stretch): `hardware.graphics` with `intel-compute-runtime` + `level-zero`, pass `/dev/dri` into an IPEX-LLM or llama.cpp SYCL/Vulkan image; benchmark tokens/s vs CPU. Known blocker: Level Zero init crashes on Panther Lake (intel/compute-runtime #918/#920). AC: written benchmark result and go/no-go.
- **5.5** NPU trial (stretch): check `intel-npu-driver` availability in nixpkgs, OpenVINO runtime. AC: go/no-go note.

### Phase 6: Development environment (Shopify scripting)
- **6.1** `home-manager` for `ops`: shell, git, tmux (port NAS `tmux.conf`), starship, direnv. AC: login shell matches WSL config.
- **6.2** Dev shells in `dev/`: `shopify` (Node + Shopify CLI + Ruby if needed), `python` (uv), `scripting`. AC: `nix develop .#shopify` gives working `shopify version`.
- **6.3** Shopify API tokens via sops → env in dev shell only, never in compose. AC: token available in shell, absent from repo history.
- **6.4** VS Code Remote-SSH over Tailscale + `nix-ld` for binaries that expect FHS. AC: open a project on nuc from workstation VS Code.
- **6.5** Optional: scheduled scripts as systemd timers declared in Nix (e.g. nightly Shopify report). AC: one timer runs a hello script.

### Phase 7: Hardening, DR (disaster recovery), and write-up
- **7.1** DR drill: full reinstall from flake + restic restore onto the same NVMe (or the second slot), time it. AC: under 1 hour, runbook updated.
- **7.2** Security review: `ssh` config audit, firewall rules dump, Tailscale ACLs, container users non-root where images allow, Docker socket not exposed. AC: findings closed or accepted in ADR.
- **7.3** SMART (Self-Monitoring, Analysis and Reporting Technology) + btrfs scrub timers, temperature monitoring (fanned unit, 120 W adapter) in Grafana. AC: scrub monthly, SMART alert tested.
- **7.4** Secure Boot with `lanzaboote` (stretch). AC: `bootctl status` shows Secure Boot enabled.
- **7.5** CV write-up: `docs/writeup.md` explaining the pipeline, decisions, and metrics (deploy latency, DR time). AC: reviewed.

### Phase 8 (stretch): Kubernetes
- **8.1** ADR: K3s vs staying on compose, with the trigger conditions for migrating.
- **8.2** `services.k3s` single node alongside Docker (or replace Docker with containerd), Flux or Argo pointed at the same repo.
- **8.3** Migrate one low-risk stack (observability) to Helm; compare ops overhead.
- **8.4** Decide: migrate games/LLM or stop. AC: decision recorded.

## Assumptions to flag

- Hostname `nuc` and user `ops` are placeholders, change in ticket 1.3 if preferred.
- Second M.2 slot stays empty for now; plan treats 1 TB as shared budget with per-stack quotas.
- Docker rather than Podman is assumed; ADR 0006 in ticket 3.1 can flip it before any stack depends on it.
- Router supports DHCP reservations and port forwarding.
