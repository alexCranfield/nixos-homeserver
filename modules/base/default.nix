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
{ lib, ... }:
{
  # Boot policy. mkDefault because systemd-boot assumes UEFI, which is true of
  # the nuc but need not be of a future host; a non-UEFI machine can then set
  # its own value without an evaluation conflict. This is the fallback case the
  # header describes.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
}
