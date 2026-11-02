# ADR 0013: A tenant's dev environment and scheduled jobs run in two microVMs, cut off from everything but the internet

Date: 2026-11-02. Status: accepted.

## Context

A friend of Alex (the tenant, below) wants to build small automations against
their online store with Claude Code: jobs that update the store's content
through its API (application programming interface) and email people, on a
schedule. They need somewhere to develop and somewhere to run the jobs. They
are comfortable on the command line, and today they run things by hand.

`docs/PLAN.md` Phase 6 planned this as dev shells, API tokens and systemd
timers for the `ops` user on the host itself (6.2, 6.3, 6.5). That fitted
Alex's own scripting, but not someone else's code. The tenant's code, its
dependencies and an AI (artificial intelligence) agent running commands for
them would all run with the host's privileges, beside the game servers, the
monitoring and the secrets of every other service.

Five ways to run the tenant's work were compared:

- **A. On the host, as Phase 6 planned.** Simplest, no isolation at all.
- **B. A Compose stack like the game servers (ADR 0002).** Containers under
  rootful Docker (ADR 0006): an escape from a container is root on the nuc,
  and the tenant's compose file could itself mount the Docker socket or `/`.
- **C. A hardened container**, with gVisor (`runsc`) or user namespaces.
  A narrower boundary than B, but still the host's kernel, and gVisor breaks
  some tools a developer expects.
- **D. Kubernetes (K3s) CronJobs.** Scheduling with retries and history, but
  ADR 0002 keeps K3s a stretch phase (ADR 0008, reserved), and it would
  bring an API server and network plugins for a handful of jobs, with the
  same container boundary as B.
- **E. MicroVMs**, small NixOS virtual machines declared with microvm.nix,
  each with its own kernel.

What mattered:

| | A | B | C | D | E |
|---|---|---|---|---|---|
| Tenant code or agent compromised | Host | One escape from root | Narrower, same kernel | Same as B | Contained to the VM |
| The tenant's own compose file | n/a | Can ask for the socket or `/` | Restricted | Restricted | Anything, inside the VM |
| Declared in Nix like the rest | Yes | Yes | Mostly | Partly | Yes |
| Fixed cost | None | Low | Low | High | A fixed share of RAM (random access memory) |

## Decision

1. **Two microVMs, declared in this repo with microvm.nix, on qemu.**
   - `tenant-dev` is where the tenant develops: they SSH in over a Tailscale
     share and run Claude Code, Docker and their tools there, with sudo.
   - `tenant-run` is production: it pulls the `main` branch of the tenant's
     private repository every few minutes and runs its Compose stack, in
     which supercronic (a cron built for containers) runs the jobs on the
     schedule the repository declares. The tenant has no shell on it.
   - qemu rather than cloud-hypervisor, because in the microvm.nix pinned
     here only qemu's runner passes systemd credentials into the guest,
     which is how the VMs get their secrets. Ticket 6.8 confirms it on the
     nuc.
2. **Both VMs reach the internet and the nuc's DNS (Domain Name System), and
   nothing else.** They sit on routed tap interfaces with their own nftables
   rules: no LAN (local area network), no router (its public address
   included, where it answers from the LAN too), no service on the nuc but
   DNS, no Docker network, no tailnet address and not each other. Their DNS
   is a second Blocky of their own on the host's tap address, 10.88.0.1,
   with the LAN Blocky's lists and query log but none of its LAN names: the
   LAN Blocky answers its local records and private hosts file, reverse
   lookups included, before any per-client blocking, so a VM asking it could
   read back the house's device names. Port 53 is opened on the tap
   interfaces for that Blocky alone, which extends ADR 0012 (port 53 on
   `lan0` only). Their lookups are filtered, and logged under their VM
   names in the same query log, with the same alerts.
3. **Nothing is public.** The store's pages, the class calendar among them,
   stay on the store's own platform, and the jobs update them through its API.
   ADR 0011 stands: nothing on the nuc is reachable from the internet.
4. **The tenant's code lives in a private repository** under Alex's account,
   with the tenant as a collaborator. A merge to `main` needs a pull request
   with passing CI (continuous integration), and the dev VM's token cannot
   push to `main`, so an experiment in dev does not reach production by
   accident. The repository's URL, the deploy key and the tenant's SSH key
   are in sops; nothing in this repository names the tenant or their
   business.
5. **Dev and production have separate secrets.** The tenant's app secrets are
   sops files in their own repository: the production file is encrypted to
   the runner's key and the tenant's own key, the dev file to the dev VM's
   key and theirs. Claude Code in dev cannot decrypt production.
6. **Job failures go to the tenant, platform faults to Alex.** A failed job
   or deploy posts to the tenant's own webhook. Alex's Discord hears about
   the VMs and the deploy loop only: a VM down or restarting, a deploy
   failing for long, a disk filling.
7. **No backups of the VMs.** The code is in GitHub, and customer data stays
   on the store's platform, which is the source of truth. The VM images are
   excluded from restic, so no customer's personal data reaches the NAS
   (network-attached storage).

Phase 6 items 6.2, 6.3 and 6.5 are superseded by tickets 6.6 to 6.12;
6.1 and 6.4 stay as Alex's own environment.

## Consequences

- A compromised dependency, a bad Claude Code session or a hostile compose
  file is contained to a VM that can reach only the internet. Reaching the
  nuc means a VM escape through qemu or KVM (Kernel-based Virtual Machine),
  not a container escape.
- The VMs cost a fixed 12 GB of the nuc's 96 GB between them (8 GB for
  dev, 4 GB for the runner), and their CPU (central
  processing unit) and I/O (input/output) weights are below the game
  servers', so games and LLMs (large language models) win any contention.
- Kubernetes is not needed for this. If ADR 0008 later adopts K3s, the
  runner's jobs are a candidate workload; nothing here blocks that.
- CI does not boot the microVMs. GitHub's runners give the VM tests KVM,
  but a microVM inside a test VM would be a third level of virtualisation,
  which this repo does not rely on: it would be unaccelerated, slow and
  flaky if it ran at all. The
  network rules are tested with stand-in interfaces of the same names, the
  runner's deploy loop on a plain test node, and the real VMs by a smoke
  test on the nuc after each deploy.
- The tenant has sudo in `tenant-dev`, so they can change its Tailscale flags.
  Advertising routes needs Alex's approval in the admin console, and the
  host's rules drop the VM's traffic to the LAN whatever the VM does.
- The tenant is on Alex's tailnet as a share recipient of one device,
  `tenant-dev`, never the nuc. The access policy lets share recipients reach
  that device's SSH port only, and gives the device no access to anything;
  friends who play games are not shared `tenant-dev`, and the tenant is not
  shared the nuc, so neither rule widens the other or ADR 0011's game-port
  rule. Whether a tagged device can be
  shared, and how many shares the plan allows, are checked on the live
  tailnet in ticket 6.10, as ADR 0011 did for games.
- The tenant sees their jobs through failure posts and per-job metrics; a
  view of their own runs that does not open the nuc's dashboards is ticket
  6.12.
- Offboarding is stopping the VMs, deleting their images, revoking the share,
  the deploy key and the auth key, and archiving the private repository.
- microvm.nix tracks nixpkgs closely and has no release tags. It is pinned
  by explicit URL and follows this flake's nixpkgs (ADR 0007), and the bump
  to NixOS 26.11 has to keep it in step.
