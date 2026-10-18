# The nuc's hardware, as detected on the machine itself (ticket 1.6, #13), from
# the live USB on 2026-10-18:
#
#   nixos-generate-config --show-hardware-config --no-filesystems
#
# `--no-filesystems` because the disk is declared in disko.nix, which generates
# fileSystems and swapDevices; listing them here too would conflict. The rest
# is the command's output, formatted. To check it still matches, run the
# command on the nuc and compare.
#
# Notes on the output:
#  - usbhid is not in the list, as no keyboard was plugged in. The keyboard
#    still works at the disk passphrase prompt: NixOS's default initrd modules
#    include usbhid and hid_generic.
#  - The NPU (neural processing unit) line adds the Intel NPU's firmware and
#    driver, and turns on hardware.graphics, which the iGPU will want anyway.
#  - nixpkgs.hostPlatform and the microcode line repeat default.nix, at a lower
#    priority (mkDefault).
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.npu.enable = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
