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
#  - The test writes /tmp/disk.key itself; on the real install it is typed at
#    the nuc's console (docs/runbooks/install.md).
#  - QEMU's TPM is emulated, so the NUC's firmware TPM and its real PCR 7 value
#    are first exercised on the hardware.
#
# On the workstation the firmware often crashes or hangs under its nested KVM
# (#80), so a local failure before Linux starts says nothing about the change.
# docs/runbooks/ci.md has how to recognise one, and `just vm-test-tcg disk-tpm`.
{
  pkgs,
  inputs,
  lib,
}:
let
  passphrase = "test passphrase, not the real one";
  # A PCR 7 value this firmware never produces, for the negative control.
  wrongPcr7 = lib.strings.replicate 8 "deadbeef";
  # Every filesystem the real host mounts, disko's and any other module's.
  # The test node cannot supply these itself: the test framework replaces its
  # `fileSystems`, so they come from the host's own configuration.
  hostFileSystems = inputs.self.nixosConfigurations.nuc.config.fileSystems;
  # The ones a boot must have mounted. A mount that may fail or wait
  # (`nofail`, `noauto`, an automount, a network share) does not stop the
  # boot, so the test does not demand it; one on a device the VM (virtual
  # machine) lacks, such as a second disk, needs an override here.
  mustMount = lib.filterAttrs (
    _: fs:
    !lib.any (o: lib.elem o fs.options) [
      "nofail"
      "noauto"
      "x-systemd.automount"
      "_netdev"
    ]
  ) hostFileSystems;
in
pkgs.testers.runNixOSTest {
  name = "disk-tpm";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc =
    { config, ... }:
    {
      imports = [ ../hosts/nuc ];
      # The host's stacks pull images, and the build sandbox has no internet;
      # tests/compose-stack.nix covers them.
      homeserver.stacks = lib.mkForce { };
      # The host's Tailscale key is a sops secret no test VM can decrypt, so
      # leave Tailscale logged out, as it was before #14: without this,
      # tailscaled-autoconnect runs `tailscale up` with an empty key and holds up
      # multi-user.target until it times out. tests/tailscale.nix tests the join.
      services.tailscale.authKeyFile = lib.mkForce null;

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

      # The machine as installed: booted from the layout disko created, with
      # every mount the host has, not disko's alone. With disko's alone, a
      # mount added elsewhere that cannot succeed passed CI and would have
      # stopped the nuc's next boot in emergency mode (#19). /boot stays on
      # the test VM's boot disk, which holds the boot loader.
      specialisation.installed.configuration = {
        virtualisation.useDefaultFilesystems = lib.mkForce false;
        virtualisation.fileSystems = lib.mkMerge [
          hostFileSystems
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
      HOST_MOUNTS = ${builtins.toJSON (builtins.attrNames mustMount)}
    ''
    + builtins.readFile ./disk-tpm.py;
}
