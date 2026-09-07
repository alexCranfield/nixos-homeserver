# ADR 0001: NixOS as the server operating system

Date: 2026-09-07. Status: accepted.

## Context
The previous NAS project managed Debian/OMV with Ansible. It worked, but a rebuild meant reinstalling the OS by hand and replaying playbooks whose result depended on what apt had at the time. This server should be reinstallable from the repo alone, with updates that can be rolled back atomically.

## Decision
Run NixOS 26.05 (stable) with the whole system declared in a flake: disks (disko), users, SSH, firewall, Docker, services, timers. Track the stable channel and bump the input at each release (26.11 next). Use `linuxPackages_latest` because the Panther Lake Xe3 iGPU and NIC drivers need a current kernel.

## Consequences
- One command (`nixos-anywhere`) installs the machine; every change is a commit.
- Rollback is a bootloader menu entry or a `git revert`.
- Learning curve is real; the module language and error messages are unfamiliar. Mitigated by building a QEMU VM of the config locally before deploying.
- Some Intel GPU tooling lands in nixpkgs later than in Ubuntu; acceptable because LLM work starts on CPU.
