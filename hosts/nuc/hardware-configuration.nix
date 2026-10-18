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
#  - usb_storage and sd_mod are there for the live USB stick, which was
#    plugged in. usbhid is not, as no keyboard was. The keyboard still works
#    at the disk passphrase prompt: NixOS's default initrd (early boot
#    environment) modules include usbhid and hid_generic.
#  - The command also wrote `hardware.cpu.intel.npu.enable = true;`, left out
#    here. The NPU (neural processing unit) works without it: its kernel
#    driver, intel_vpu, is part of the kernel, and its firmware comes with
#    linux-firmware. The line adds the user-space driver, Level Zero and
#    hardware.graphics (0.9 GiB), which nothing uses yet, and an older copy of
#    the firmware that replaces linux-firmware's. The NPU and iGPU (integrated
#    graphics) trials, tickets 5.4 (#37) and 5.5 (#38), decide whether to add it.
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
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
