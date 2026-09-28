# ADR 0007: Nix distribution policy for workstation and server

Date: 2026-09-07. Status: accepted.

## Context

The workstation runs Determinate Nix 3.22.3 (upstream Nix 2.35.2), installed by
the Determinate installer in ticket 0.1. The server will run whatever NixOS
stable ships, which is 2.34.8 on the `nixos-26.05` branch. That is a one minor
version gap, in the awkward direction: the development machine is newer than the
deployment target, so code can evaluate locally and fail on the server.

Determinate Nix is a downstream distribution rather than a repackaging. It adds
lazy trees, parallel evaluation and a stability guarantee for flakes that
upstream has not made. Its installer also rewires the bare `nixpkgs` flake
reference to a FlakeHub weekly snapshot and adds FlakeHub as a trusted binary
cache. A NixOS module exists to install it on the server if we wanted the two
machines to match exactly.

The question is whether to commit to matching Nix versions across the two.

## Decision

No. Match inputs, not versions.

- The workstation keeps Determinate Nix, for the installer, the clean uninstall
  and the developer experience.
- The server runs the Nix that NixOS stable ships. No `nix.package` override, no
  extra flake input.
- The flake depends on no distribution-specific behaviour. `nixpkgs` is always
  pinned by explicit URL, never by the bare name, so the workstation's FlakeHub
  redirect cannot leak into a build. Nothing may rely on lazy trees or parallel
  evaluation being present.
- Revisit only if the two ever drift more than one NixOS release apart.

## Consequences

- What gets built is determined by the locked inputs, not by which Nix evaluates
  them. An identical `flake.lock` produces identical derivations on both
  machines despite the version gap. This is the property that makes the decision
  safe, and it is why `flake.lock` must always be committed.
- The server resembles its documentation. The manual, the wiki and forum answers
  all assume the shipped Nix, which matters most when debugging an unattended
  machine under time pressure.
- No third-party flake sits on the critical path of a machine that rebuilds
  itself from `main`, and the weekly lock bump has one fewer input that could
  break a deploy.
- The residual risk is real but cheap. Code that evaluates on the newer
  workstation may fail on the older server. When that happens comin's build
  fails, the previous generation keeps running, and the notification from ticket
  2.5 fires. A deploy does not land; the machine does not break.
- CI (continuous integration) was expected to use the Determinate installer and
  share the workstation's blind spot. Superseded by the amendment below.
- The gap self-corrects. Bumping the flake to the next NixOS release moves the
  server's Nix forward at the same time.

## Amendment, 2026-09-27 (ticket 0.4, #4)

The flake's dev shell now carries the server's own Nix: `pkgs.nix`, which NixOS
uses as the default `nix.package` (2.34.8 today). It was already there by
accident, as a dependency of `nixos-rebuild`; ticket 0.4 made it explicit, and a
flake check (`devshell-nix-matches-server`) fails if the host ever stops using
the same package. `just check` runs inside the dev shell locally and in CI, so
both evaluate the flake with exactly the Nix comin will use, closing the
*evaluation* blind spot described above. The installed Nix, Determinate on the
workstation and upstream in CI, only starts the dev shell and runs the daemon
that builds.

- The Decision stands: the workstation keeps Determinate Nix, the server keeps
  the NixOS default. Only the Nix used *inside the repo* changes.
- Inside the repo directory (direnv loads the dev shell), `nix` is the server's
  version. It warns `unknown setting 'eval-cores'` and `'lazy-trees'`, because
  the workstation's `nix.conf` is written for Determinate Nix. Harmless; those
  Determinate features are unavailable in the repo, which is the point.
- CI installs upstream Nix with `cachix/install-nix-action`, because Determinate's
  installer action now treats upstream Nix as unsupported. See
  `docs/runbooks/ci.md`.
