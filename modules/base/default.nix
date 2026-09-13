# Configuration applied to every host.
#
# Nothing host-specific belongs here. Identity, hardware and
# `system.stateVersion` live in `hosts/<name>/`, so a second machine cannot
# inherit the first one's values.
#
# This module previously set `networking.hostName`, which was wrong: two modules
# defining one option is an evaluation error rather than last-one-wins, so any
# second host would have failed to build. An option with a sensible fallback can
# live here as `lib.mkDefault`, which a host may then override. Identity has no
# sensible fallback, so it does not.
#
# Deliberately minimal. Ticket 1.3 (#10) adds the ops user, sshd, nix settings,
# garbage collection, the latest kernel, microcode and locale.
{ ... }:
{
  # Boot policy. The same on any machine this repo would build.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
