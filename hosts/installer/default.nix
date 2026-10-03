# Live USB image for surveying and installing the nuc (tickets 1.1 #8, 1.6 #13).
#
# The stock NixOS minimal ISO (disk image) boots the default LTS (long-term
# support) kernel, which may not drive Panther Lake's Xe3 iGPU (integrated
# graphics) or NICs (network interface cards). A hardware check on that kernel
# says little about the installed system, which runs `linuxPackages_latest`
# (ADR, Architecture Decision Record, 0001). This image boots the same kernel
# series the server will, and lets the workstation key in over SSH so survey
# output can be collected from WSL (Windows Subsystem for Linux) instead of
# retyped from the console.
#
# Build it with `just iso`. Nothing here is installed onto the nuc.
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # The installer enables ZFS (Zettabyte File System), whose out-of-tree module
  # often lags the newest kernel and then breaks the build. The nuc uses btrfs.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # The minimal ISO already runs sshd, but root has no key, and an empty
  # password is refused over SSH. Only the ops key may log in.
  users.users.root.openssh.authorizedKeys.keyFiles = [ ../../keys/ops.pub ];

  # Tools for the hardware survey in ticket 1.1 (#8) and the TPM (Trusted
  # Platform Module) check that decides ticket 1.0 (#57).
  environment.systemPackages = with pkgs; [
    pciutils # lspci -k: which driver bound to the iGPU and NICs
    usbutils
    dmidecode # BIOS (firmware) version, RAM part numbers
    lshw
    nvme-cli
    smartmontools
    ethtool # link speed of each 2.5GbE port
    tpm2-tools # is a TPM 2.0 present, and what does it report
  ];
}
