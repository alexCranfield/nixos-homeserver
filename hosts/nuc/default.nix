# The nuc host: an ASRock Industrial NUC BOX-358H.
#
# Everything host-specific lives here: identity, hardware, and the state
# version. Shared policy lives in ../../modules/base.
{ inputs, pkgs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
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
  # microcontroller blobs. The NICs are expected to use igc, which needs none;
  # the hardware survey (#8) confirms the driver.
  hardware.enableRedistributableFirmware = true;

  # The root is encrypted (ADR 0009, hosts/nuc/disko.nix). systemd in the initrd
  # (early boot environment) is what unlocks it with a TPM (Trusted Platform
  # Module) key, and its TPM support adds the TPM software (tpm2-tss) and units
  # to the initrd. Both are the 26.05 defaults, stated because the unlock
  # depends on them. The tpm_crb driver Intel's firmware TPM uses is built into
  # linuxPackages_latest, so no kernel module is involved.
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.tpm2.enable = true;

  # Records the release at which this machine's persistent state was created.
  # Per host, because a second machine installed later starts at a later
  # release. Never changed, not even when the nixpkgs input moves on.
  system.stateVersion = "26.05";
}
