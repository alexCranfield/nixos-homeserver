# The nuc's disk, declared. disko turns this into the partitioning script that
# nixos-anywhere runs at install (#13), and into the `fileSystems`, `swapDevices`
# and `boot.initrd.luks.devices` this host boots with.
#
# GPT (GUID Partition Table) with two partitions:
#
#   ESP (EFI System Partition), 1 GiB, vfat, /boot. Unencrypted, as the
#     firmware must read it. Holds systemd-boot and one kernel and initrd per
#     generation; 1 GiB should hold the ten generations in system.nix with
#     room over, to be measured after the install (#13).
#   cryptroot, the rest. LUKS2 (Linux Unified Key Setup, version 2), holding one
#     btrfs filesystem with the subvolumes below (ADR, Architecture Decision
#     Record, 0009).
#
# Changing anything here on an installed machine does nothing to the disk.
# disko only partitions at install; after that this file just describes what is
# there, and a mismatch shows up as a failed mount at boot.
{
  disko.devices.disk.main = {
    type = "disk";
    # The only NVMe (Non-Volatile Memory Express) drive. Kernel names follow probe
    # order, so a second drive in the empty M.2 slot could take this name.
    # Before fitting one, change this to the drive's /dev/disk/by-id path; see
    # docs/runbooks/hardware.md.
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            # Only root can read the boot loader's files, including its random
            # seed.
            mountOptions = [ "umask=0077" ];
          };
        };

        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # The recovery passphrase, read only while formatting. nixos-anywhere
            # copies it here with `--disk-encryption-keys` (ADR 0009); it is
            # never in this repo or the Nix store.
            passwordFile = "/tmp/disk.key";
            settings = {
              # TRIM (discard) reaches the SSD. It reveals which blocks are in
              # use, never their content; ADR 0009 accepts that.
              allowDiscards = true;
              # Unlock with a TPM (Trusted Platform Module) key, falling back
              # to the passphrase prompt; until `systemd-cryptenroll` adds a TPM
              # key after the first boot, the prompt is all there is. Stated
              # for clarity rather than need: with systemd 260 the disk test
              # unlocks from the TPM without this line too, because a TPM key
              # enrolled in the LUKS header is tried on its own.
              crypttabExtraOpts = [ "tpm2-device=auto" ];
            };
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes =
                let
                  # zstd level 1, the fastest, rather than btrfs's default of 3:
                  # nearly free on this CPU, at some cost in ratio. Not measured
                  # on this machine's data.
                  compressed = [
                    "compress=zstd:1"
                    "noatime"
                  ];
                in
                {
                  "@root" = {
                    mountpoint = "/";
                    mountOptions = compressed;
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = compressed;
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = compressed;
                  };
                  # Container data, /srv/data/<stack> (ticket 3.3, #24).
                  "@srv" = {
                    mountpoint = "/srv";
                    mountOptions = compressed;
                  };
                  # Docker's images and named volumes (ticket 3.1, #22).
                  # Compressed like the rest. Unpacked image layers are mostly
                  # binaries and libraries, which usually shrink, and files that
                  # are already compressed cost little: btrfs stops trying on a
                  # file whose first data does not shrink. Data worth keeping
                  # lives in /srv/data instead.
                  "@docker" = {
                    mountpoint = "/var/lib/docker";
                    mountOptions = compressed;
                  };
                  # Snapshots of the others, for the backups in ticket 3.5 (#26).
                  # A snapshot is not itself snapshotted, so it lives apart.
                  "@snapshots" = {
                    mountpoint = "/.snapshots";
                    mountOptions = compressed;
                  };
                  # A swapfile on disk rather than zram (compressed swap in RAM).
                  # Swap is the margin for the day a large model and the game
                  # servers together outgrow 96 GB; zram can only squeeze what is
                  # already in RAM, so it gives the least room exactly then.
                  # No hibernation, so 16 GiB is a margin, not RAM-sized.
                  #
                  # Its own subvolume because btrfs cannot snapshot a subvolume
                  # holding an active swapfile. `btrfs filesystem mkswapfile`
                  # creates it uncompressed and copy-on-write disabled, as swap
                  # requires. Inside LUKS, so swapped-out memory is encrypted too.
                  "@swap" = {
                    mountpoint = "/.swapvol";
                    swap.swapfile.size = "16G";
                  };
                };
            };
          };
        };
      };
    };
  };
}
