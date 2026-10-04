# PLACEHOLDER kernel module lists, until the install.
#
# Ticket 1.6 (#13) replaces them with the real output of
# `nixos-generate-config --show-hardware-config --no-filesystems` run on the NUC
# itself. `--no-filesystems` because the disk is declared in disko.nix, which
# generates fileSystems and swapDevices; listing them here too would conflict.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Announced on every build and in CI so the placeholder cannot reach a real
  # machine unnoticed. Deleting this warning is part of ticket 1.6 (#13).
  warnings = [
    "hosts/nuc/hardware-configuration.nix is still the placeholder; replace it in ticket 1.6 (#13)"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usbhid"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

}
