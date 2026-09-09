# Base configuration applied to every host.
#
# Deliberately minimal. Ticket 1.3 (#10) adds the ops user, sshd, nix settings,
# garbage collection, the latest kernel, microcode and locale. Only what the
# skeleton needs to build lives here for now.
{ ... }:
{
  networking.hostName = "nuc";

  # Enough of a bootloader for the closure to build. Ticket 1.3 (#10) adds
  # configurationLimit and the rest of the boot policy.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Records the release this machine's persistent state was created at. Never
  # changed, not even when the nixpkgs input moves to a newer release.
  system.stateVersion = "26.05";
}
