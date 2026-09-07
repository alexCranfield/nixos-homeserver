# Learning path

This project is deliberately a learning exercise, not just a build. This file
sequences the reading against the phases in `docs/PLAN.md` so you meet each idea
shortly before you need it.

## How to use this

**Read one phase ahead, not the whole list.** Nix material makes very little
sense before you have a config that misbehaves. The single most effective loop
is: read the short thing, build a VM (virtual machine) with `just vm`, break it
on purpose, roll it back.

**Expect the Nix learning curve to be genuinely bad**, and know why. You are
learning three separate things that all look alike: the Nix *language* (lazy,
functional, small), the *Nixpkgs idioms* (how packages and overlays are built),
and the *NixOS module system* (options, defaults, priorities). Most confusion
comes from not knowing which of the three is currently biting you. When stuck,
ask that question first.

**Read other people's configurations.** Searching GitHub for `nixosConfigurations`
turns up hundreds of public, working systems. This is how most people actually
learn the module system, and it is faster than any tutorial for "how do I
express this specific thing".

---

## Foundations, before Phase 0

| Resource | Why | Time |
|---|---|---|
| [Zero to Nix](https://zero-to-nix.com/) | Determinate Systems' introduction. Flakes-first and matches the installer we used, so nothing contradicts what is on your machine. Start here. | ~2 h |
| [Nix from First Principles: Flake Edition](https://tonyfinn.com/blog/nix-from-first-principles-flake-edition/) | Tony Finn builds the flake world up from nothing rather than handing you a template. The part that makes the language click. | ~half a day |
| [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/) | The best single beginner book for exactly our setup: NixOS, flakes, home-manager. Treat as the main text and work through it during Phases 0 and 1. | ~a week, spread out |

## Reference, to bookmark rather than read

- [search.nixos.org](https://search.nixos.org) — packages and, critically, **NixOS
  options**. The options tab answers most "how do I configure X" questions faster
  than any prose.
- [noogle.dev](https://noogle.dev) — searchable Nixpkgs library functions, for
  when you need `lib.mkIf` or `lib.mapAttrs'` and cannot remember the signature.
- [NixOS Manual](https://nixos.org/manual/nixos/stable/) and
  [Nixpkgs Manual](https://nixos.org/manual/nixpkgs/stable/) — authoritative, dry.
- [Official NixOS Wiki](https://wiki.nixos.org) — practical recipes. Note this
  replaced the older `nixos.wiki`; prefer `wiki.nixos.org`.
- [nix.dev](https://nix.dev) and the [Learn Nix hub](https://nixos.org/learn/) —
  official task-oriented guides.
- [Awesome Nix](https://github.com/nix-community/awesome-nix) — index of the
  wider ecosystem.
- [NixOS Discourse](https://discourse.nixos.org) — genuinely helpful forum, and
  the place to ask when the wiki is silent.

## Phase 1: install and base OS

- [disko](https://github.com/nix-community/disko) — declarative partitioning. Read
  the examples directory; our btrfs subvolume layout is a variation on one of them.
- [nixos-anywhere](https://nix-community.github.io/nixos-anywhere/) — the
  installer. The quickstart is short and worth reading fully before ticket #13.
- [btrfs documentation](https://btrfs.readthedocs.io/) — specifically subvolumes
  and snapshots, which the backup design in Phase 3 depends on.

## Phase 2: GitOps and updates

- [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) —
  Michael Nygard's 2011 post that started ADRs (Architecture Decision Records).
  Short, and it explains the format used in `docs/adr/`.
- [adr.github.io](https://adr.github.io/) — templates and variations on the above.
- [OpenGitOps principles](https://opengitops.dev/) — the four principles that
  define GitOps. Useful vocabulary for describing what comin does.
- [comin](https://github.com/nlewo/comin) — read the docs directory, especially
  the how-tos, before ticket #16.

## Phase 3: containers, observability, backups

- [Docker Compose specification](https://docs.docker.com/compose/) — worth
  reading properly once, since every game server stack is a compose file.
- [restic documentation](https://restic.readthedocs.io/) — the design section
  explains deduplication and why `restic check` matters.
- The **3-2-1 backup rule**: three copies, on two media types, one off site. Our
  Phase 3 design satisfies the first two. The NAS is not off site, which is a
  known gap worth revisiting.
- [Prometheus documentation](https://prometheus.io/docs/) — start with the
  querying basics; PromQL is the part that takes practice.
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/), chapter 6,
  *Monitoring Distributed Systems*. The distinction between symptom-based and
  cause-based alerting is exactly what ticket #27 is about, and it is the
  difference between alerts you act on and alerts you mute.

## Phase 4: game servers

- [itzg/docker-minecraft-server docs](https://docker-minecraft-server.readthedocs.io/) —
  unusually good documentation for a community image, and the reference for
  ticket #28.
- [systemd resource control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html) —
  `MemoryMax`, `CPUWeight` and cgroups, behind the resource policy in ticket #32.

## Phase 5: local LLMs

- [Ollama documentation](https://github.com/ollama/ollama/tree/main/docs) —
  the API and model file format.
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — read the quantization
  notes. Understanding what Q4_K_M actually trades away is what lets you pick
  models sensibly for 96 GB of RAM.
- [IPEX-LLM](https://github.com/intel/ipex-llm) — Intel's acceleration stack, for
  the iGPU trial in ticket #37.

## Phase 6: development environment

- [home-manager manual](https://nix-community.github.io/home-manager/) — user
  environment as code.
- [direnv wiki](https://github.com/direnv/direnv/wiki/Nix) — the Nix integration
  patterns, beyond the `use flake` we already have.

## Phase 7: hardening and disaster recovery

- [sops](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age) —
  read age's design rationale; it explains why it replaced GPG for this use.
- [How Tailscale works](https://tailscale.com/blog/how-tailscale-works) — the
  clearest explanation of NAT traversal and WireGuard key exchange you will find.
  Worth reading even though the setup is three lines of config.
- [Google SRE Workbook](https://sre.google/workbook/table-of-contents/) on
  postmortems. When the disaster recovery drill in ticket #44 goes sideways,
  writing it up blamelessly is the practice worth building.

## Phase 8: Kubernetes, if you get there

- [k3s documentation](https://docs.k3s.io/) — the lightweight distribution.
- [Flux documentation](https://fluxcd.io/flux/) — GitOps for Kubernetes, the
  same idea as comin one layer up.
- Read ADR 0008 before either. The decision of whether to do this at all is more
  valuable than the implementation.

## Going deeper, much later

- [Nix Pills](https://nixos.org/guides/nix-pills/) — builds derivations and
  Nixpkgs from first principles. Genuinely hard, and unnecessary until you want
  to know *why* rather than *how*. Worth it after a few months of use.
