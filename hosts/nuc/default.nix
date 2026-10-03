# The nuc host: an ASRock Industrial NUC BOX-358H.
#
# Everything host-specific lives here: identity, hardware, and the state
# version. Shared policy lives in ../../modules/base.
{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/base
  ];

  networking.hostName = "nuc";
  nixpkgs.hostPlatform = "x86_64-linux";

  # Panther Lake's Xe3 iGPU and NICs need a current kernel (ADR 0001), and
  # the live USB in hosts/installer boots the same series.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  hardware.cpu.intel.updateMicrocode = true;
  # Firmware the kernel loads at boot, notably the Xe3 iGPU's GuC and HuC
  # microcontroller blobs; the igc NIC driver needs none.
  hardware.enableRedistributableFirmware = true;

  # Records the release at which this machine's persistent state was created.
  # Per host, because a second machine installed later starts at a later
  # release. Never changed, not even when the nixpkgs input moves on.
  system.stateVersion = "26.05";
}
