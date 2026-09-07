# ADR 0003: Pull-based deployment with comin, validated by GitHub Actions

Date: 2026-09-07. Status: accepted.

## Context
Options were: push from the workstation (`nixos-rebuild --target-host`), a self-hosted GitHub Actions runner on the server, or the server pulling from the repo. The repo is public so it can serve as portfolio evidence, which makes a self-hosted runner risky: anyone's pull request could run code on the machine.

## Decision
GitHub-hosted Actions run `nix flake check`, build the system closure and check formatting on every pull request and push. The server runs comin, which polls `main` roughly every 60 seconds and runs `nixos-rebuild switch` on new commits. A manual push target remains for emergencies. A weekly Action opens a pull request bumping `flake.lock`.

## Consequences
- Nothing on the server accepts inbound connections for deployment.
- Deploy latency is about a minute after merge.
- CI cannot test hardware-specific behaviour; the VM build catches most config errors.
- Broken commits on `main` are caught by CI before merge; if one slips through, the previous generation still boots.
