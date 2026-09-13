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
{ lib, inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  # Secrets are decrypted at activation into /run/secrets, never into the Nix
  # store, which is world readable. See ADR 0004.
  #
  # The default key source is the host's own SSH host key, converted to age.
  # The nuc's key becomes a recipient in ticket 1.7 (#14), once the machine
  # exists. No secret is declared here on purpose: a host that cannot decrypt a
  # declared secret fails activation, which would have booby-trapped the first
  # install in ticket 1.6 (#13). Real secrets arrive with the services that need
  # them, by which point the host key is a recipient.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = ../../secrets/test.yaml;

  # Boot policy. mkDefault because systemd-boot assumes UEFI, which is true of
  # the nuc but need not be of a future host; a non-UEFI machine can then set
  # its own value without an evaluation conflict. This is the fallback case the
  # header describes.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
}
