# Acceptance test for tickets 1.2 (#9) and 1.0 (#57): the nuc's real disk layout,
# encrypted, unlocks as ADR (Architecture Decision Record) 0009 says it will.
#
# One VM (virtual machine) running the nuc configuration, with a blank second
# disk and an emulated TPM (Trusted Platform Module). The script does what the
# install will do: disko formats the blank disk from hosts/nuc/disko.nix, the
# machine boots from it and asks for the passphrase, a TPM key is enrolled, and
# the next boot unlocks unattended.
#
# The boot is measured: the VM boots through UEFI (Unified Extensible
# Firmware Interface) firmware with TPM support (OVMFFull, the full build of
# OVMF, the Open Virtual Machine Firmware) and systemd-boot, as the NUC does.
# The default for QEMU (Quick Emulator) test VMs, booting the kernel directly,
# skips the firmware, so nothing would be measured into PCR (Platform
# Configuration Register) 7 and a key sealed to it would prove nothing.
#
# What it does not cover, left to the real install (#13):
#  - The boot loader runs from the test VM's own boot disk, not from the ESP
#    (EFI System Partition) disko creates. The test checks that ESP's size and
#    format; nixos-anywhere installs the loader to it, and /boot's umask=0077 is
#    not checked.
#  - The Nix store comes from the host, not from @nix.
#  - The test writes /tmp/disk.key itself; nixos-anywhere's
#    `--disk-encryption-keys` is what puts it there for real.
#  - QEMU's TPM is emulated, so the NUC's firmware TPM and its real PCR 7 value
#    are first exercised on the hardware.
{
  pkgs,
  inputs,
  lib,
}:
let
  passphrase = "test passphrase, not the real one";
  # A PCR 7 value this firmware never produces, for the negative control.
  wrongPcr7 = lib.strings.replicate 8 "deadbeef";
in
pkgs.testers.runNixOSTest {
  name = "disk-tpm";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc =
    { config, ... }:
    let
      disko = config.disko.devices._config;
    in
    {
      imports = [ ../hosts/nuc ];

      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        # Only the full build of the firmware measures the boot into the TPM.
        efi.OVMF = pkgs.OVMFFull;
        tpm.enable = true;
        # CRB (Command Response Buffer), the interface Intel's firmware TPM
        # uses, so the tpm_crb driver is what unlocks the disk here too.
        # The NixOS test VM's x86 default is the older TIS (TPM Interface
        # Specification) interface, driver tpm_tis.
        tpm.deviceModel = "tpm-crb";
        # The installed system boots from the host's store, so the test does not
        # copy a whole closure onto the disk first.
        mountHostNixStore = true;
        # Sparse, so the 16 GiB swapfile costs no real space.
        emptyDiskImages = [ 24576 ];
        memorySize = 2048;
      };

      # The blank disk in place of the NVMe. Everything disko generates for
      # booting refers to partition labels, not to this name.
      disko.devices.disk.main.device = lib.mkForce "/dev/vdb";

      environment.systemPackages = [ pkgs.compsize ];

      # The machine as installed: booted from the layout disko created. The
      # test framework replaces `fileSystems` with its own, so disko's are
      # handed back here. /boot stays on the test VM's boot disk, which holds
      # the boot loader.
      specialisation.installed.configuration = {
        virtualisation.useDefaultFilesystems = lib.mkForce false;
        virtualisation.fileSystems = lib.mkMerge [
          disko.fileSystems
          { "/boot".device = lib.mkForce config.virtualisation.bootPartition; }
        ];
      };
    };

  # The script itself is tests/disk-tpm.py, so it reads as Python in an editor.
  # Nix knows a few values the script needs; they go in front of it as
  # constants. toJSON because a JSON string is also a valid Python string, so a
  # quote in a value cannot break the script.
  testScript =
    { nodes, ... }:
    let
      build = nodes.nuc.system.build;
      installed = nodes.nuc.specialisation.installed.configuration.system.build.toplevel;
    in
    ''
      PASSPHRASE = ${builtins.toJSON passphrase}
      WRONG_PCR7 = ${builtins.toJSON wrongPcr7}
      FORMAT_MOUNT = ${builtins.toJSON (lib.getExe build.formatMount)}
      UNMOUNT = ${builtins.toJSON (lib.getExe build.unmount)}
      INSTALLED = ${builtins.toJSON installed}
    ''
    + builtins.readFile ./disk-tpm.py;
}
