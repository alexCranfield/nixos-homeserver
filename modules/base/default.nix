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
  # Nothing else is configured here on purpose.
  #
  #  - No secret is declared. A host that declares a secret it cannot decrypt
  #    fails activation, which would have booby-trapped the first install in
  #    ticket 1.6 (#13), before the host key becomes a recipient in 1.7 (#14).
  #  - `sops.age.sshKeyPaths` is left alone. sops-nix already derives the age
  #    key from the ed25519 entry in `services.openssh.hostKeys`, so hardcoding
  #    /etc/ssh/... would silently break a /persist layout, which the btrfs
  #    subvolumes in ticket 1.2 (#9) make likely.
  #  - `sops.defaultSopsFile` is left unset. Pointing it at the bootstrap test
  #    file would make this module depend on a throwaway artifact, and an
  #    unset default gives a clearer error than a wrong one.
  #
  # Real secrets are declared beside the service that needs them, each naming
  # its own `sopsFile`.

  # Boot policy. mkDefault because systemd-boot assumes UEFI, which is true of
  # the nuc but need not be of a future host; a non-UEFI machine can then set
  # its own value without an evaluation conflict. This is the fallback case the
  # header describes.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
}
