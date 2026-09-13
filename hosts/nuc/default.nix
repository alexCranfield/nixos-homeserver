# The nuc host: an ASRock Industrial NUC BOX-358H.
#
# Everything host-specific lives here: identity, hardware, and the state
# version. Shared policy lives in ../../modules/base.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/base
  ];

  networking.hostName = "nuc";
  nixpkgs.hostPlatform = "x86_64-linux";

  # Records the release at which this machine's persistent state was created.
  # Per host, because a second machine installed later starts at a later
  # release. Never changed, not even when the nixpkgs input moves on.
  system.stateVersion = "26.05";
}
