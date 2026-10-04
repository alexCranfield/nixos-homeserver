# Acceptance test for tickets 1.2 (#9) and 1.0 (#57): the nuc's real disk layout,
# encrypted, unlocks as ADR 0009 says it will.
#
# One VM (virtual machine) running the nuc configuration, with a blank second
# disk and an emulated TPM (Trusted Platform Module). The script does what the
# install will do: disko formats the blank disk from hosts/nuc/disko.nix, the
# machine boots from it and asks for the passphrase, a TPM key is enrolled, and
# the next boot unlocks unattended.
#
# The boot is measured: the VM boots through UEFI firmware with TPM support
# (OVMFFull) and systemd-boot, as the NUC does. QEMU's default direct kernel
# boot skips the firmware, so nothing would be measured into PCR (Platform
# Configuration Register) 7 and a key sealed to it would prove nothing.
#
# What it does not cover: the boot loader runs from the test VM's own boot disk,
# not from the ESP (EFI System Partition) disko creates. The test checks that
# ESP's size and format; nixos-anywhere installs the loader to it in #13.
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

  testScript =
    { nodes, ... }:
    let
      build = nodes.nuc.system.build;
      installed = nodes.nuc.specialisation.installed.configuration.system.build.toplevel;
    in
    ''
      import re

      PROMPT = "Please enter passphrase for disk cryptroot"

      def boot(expect_prompt):
          """Start the VM and answer the passphrase prompt, or assert it never came."""
          nuc.start()
          if expect_prompt:
              # Bounded, so a boot that never asks fails here instead of hanging
              # until CI (continuous integration) gives up.
              nuc.wait_for_console_text(PROMPT, timeout=300)
              nuc.send_console("${passphrase}\n")
          nuc.wait_for_unit("multi-user.target")
          prompted = PROMPT in nuc.get_console_log()
          assert prompted == expect_prompt, f"passphrase prompt shown: {prompted}"

      def reboot(expect_prompt):
          nuc.succeed("sync")
          nuc.crash()
          boot(expect_prompt)

      with subtest("disko formats and mounts the blank disk"):
          nuc.wait_for_unit("multi-user.target")
          nuc.succeed("printf %s '${passphrase}' > /tmp/disk.key")
          nuc.succeed("${lib.getExe build.formatMount}")
          nuc.succeed("${lib.getExe build.unmount}")
          nuc.succeed("rm /tmp/disk.key")
          nuc.succeed("${installed}/bin/switch-to-configuration boot")
          # That adds the installed system as a second boot menu entry; the
          # default stays the test system. Make it the default, as on the NUC.
          entry = nuc.succeed(
              "ls /boot/loader/entries | grep -x 'nixos-generation-[0-9]*-specialisation-installed.conf'"
          ).strip()
          nuc.succeed(f"bootctl set-default {entry}")

      with subtest("first boot stops at the passphrase prompt"):
          reboot(expect_prompt=True)

      with subtest("the root is btrfs inside LUKS2"):
          source = nuc.succeed("findmnt -no SOURCE,FSTYPE /").strip()
          print(source)
          assert source == "/dev/mapper/cryptroot[/@root] btrfs", source
          nuc.succeed("cryptsetup luksDump /dev/vdb2 | grep -qx 'Version:.*2'")
          # Discards reach the disk (ADR 0009).
          nuc.succeed("dmsetup table cryptroot | grep -q allow_discards")

      with subtest("every subvolume is mounted where disko.nix says"):
          mounts = {
              "/": "@root", "/nix": "@nix", "/home": "@home", "/srv": "@srv",
              "/var/lib/docker": "@docker", "/.snapshots": "@snapshots",
              "/.swapvol": "@swap",
          }
          for target, subvol in mounts.items():
              got = nuc.succeed(f"findmnt -no SOURCE {target}").strip()
              assert got == f"/dev/mapper/cryptroot[/{subvol}]", (target, got)

      with subtest("16 GiB of swap, inside the encrypted volume"):
          swaps = nuc.succeed("swapon --show=NAME,SIZE --noheadings --bytes").split()
          print(swaps)
          assert swaps == ["/.swapvol/swapfile", str(16 * 1024**3)], swaps

      with subtest("the ESP is 1 GiB of vfat"):
          size = nuc.succeed("lsblk -bndo SIZE /dev/vdb1").strip()
          assert size == str(1024**3), size
          nuc.succeed("test \"$(blkid -o value -s TYPE /dev/vdb1)\" = vfat")

      with subtest("data is compressed with zstd"):
          # 64 MiB of one repeated byte compresses to almost nothing, if allowed.
          nuc.succeed("head -c 64M /dev/zero | tr '\\0' a > /srv/probe && sync")
          out = nuc.succeed("compsize -b /srv/probe")
          print(out)
          assert re.search(r"^zstd ", out, re.M), "/srv/probe was not compressed"

      with subtest("PCR 7 holds a measurement, so the boot was measured"):
          pcr7 = nuc.succeed("systemd-analyze pcrs 7 --json=short")
          print(pcr7)
          assert re.search(r'"sha256":"[0-9a-f]{64}"', pcr7), pcr7
          assert '"sha256":"' + "0" * 64 + '"' not in pcr7, "PCR 7 is all zeros"

      with subtest("with a TPM key enrolled, the next boot is unattended"):
          # The command the install runbook gives, from ADR 0009.
          nuc.succeed(
              "PASSWORD='${passphrase}' systemd-cryptenroll"
              " --tpm2-device=auto --tpm2-pcrs=7 /dev/vdb2"
          )
          reboot(expect_prompt=False)
          print(nuc.succeed("cryptsetup luksDump /dev/vdb2"))
          # The recovery passphrase keeps its own slot beside the TPM key.
          nuc.succeed("cryptsetup luksDump /dev/vdb2 | grep -q systemd-tpm2")
          nuc.succeed("printf %s '${passphrase}' | cryptsetup open --test-passphrase /dev/vdb2 -")

      with subtest("a key sealed to a different PCR 7 falls back to the passphrase"):
          # What a Secure Boot or firmware change does to the real key.
          nuc.succeed(
              "PASSWORD='${passphrase}' systemd-cryptenroll --wipe-slot=tpm2"
              " --tpm2-device=auto --tpm2-pcrs=7:sha256=${wrongPcr7} /dev/vdb2"
          )
          reboot(expect_prompt=True)
          nuc.succeed("findmnt -no SOURCE / | grep -q '^/dev/mapper/cryptroot'")
    '';
}
