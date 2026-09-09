# PLACEHOLDER. The machine does not exist yet.
#
# Ticket 1.2 (#9) replaces the fileSystems below with a disko-generated layout.
# Ticket 1.6 (#13) replaces the kernel module lists with the real output of
# `nixos-generate-config --show-hardware-config` run on the NUC itself.
#
# Until then these values exist only so the closure evaluates and builds. They
# describe nothing real, and the labels are deliberately obvious so a stray
# install cannot silently succeed against the wrong disk.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usbhid"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/PLACEHOLDER-ROOT";
    fsType = "btrfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/PLACEHOLDER-BOOT";
    fsType = "vfat";
  };

  swapDevices = [ ];
}
