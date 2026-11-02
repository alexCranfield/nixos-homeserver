# Where the tenant VMs' (virtual machines') disks live, ticket 6.7 (#197).
#
# microvm.nix keeps each VM's runner and volume images under
# `microvm.stateDir`, /var/lib/microvms, and creates the directory with a
# tmpfiles `d` line. Here it is a btrfs subvolume instead (tmpfiles `v`):
#
#  - a nested subvolume is left out of snapshots of the root subvolume, and
#    out of backups, which is what ADR 0013 decides: the VMs hold no data that
#    isn't in GitHub or the tenant's store, and their customers' personal data
#    must not reach the NAS;
#  - copy-on-write is off for it (tmpfiles `h +C`), so image files created in
#    it inherit NOCOW (no copy-on-write), the usual setting for VM disks on
#    btrfs: no fragmentation from rewrites in place.
#
# tmpfiles falls back to a plain directory, silently, when the path already
# exists or when / is not itself a btrfs subvolume (tmpfiles.d(5)). On the nuc
# it is, `@root` (hosts/nuc/disko.nix); in a VM test it isn't, which is how
# tests/tenant-net.py sees the check catch the fallback.
# `microvm-state.service` checks, and every `microvm@` unit requires it, so a
# VM doesn't start on a plain directory and the failure is posted
# (modules/base/notify.nix).
#
# Two of microvm.nix's host defaults are turned off:
#
#  - KSM (kernel samepage merging) shares identical memory pages between
#    VMs, and between a VM and the host. Timing writes to a shared page can
#    show what another VM has in memory, so it stays off between tenants.
#  - qemu's bridge helper, a setuid program, would let anyone attach a tap to
#    any bridge (`allow all`). The VMs use routed taps, not bridges, so its
#    configuration allows nothing.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dir = config.microvm.stateDir;
in
{
  systemd.tmpfiles.settings."10-microvm".${dir} = lib.mkForce {
    v = {
      user = "microvm";
      group = "kvm";
      mode = "0775";
    };
    h.argument = "+C";
  };

  systemd.services.microvm-state = {
    description = "Check the microVM state directory is a NOCOW btrfs subvolume";
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.btrfs-progs
      pkgs.e2fsprogs
    ];
    script = ''
      set -eu
      dir=${lib.escapeShellArg dir}
      if ! btrfs subvolume show "$dir" > /dev/null; then
        echo "$dir is not a btrfs subvolume" >&2
        exit 1
      fi
      # lsattr prints the flags first, `C` among them when NOCOW is set.
      flags=$(lsattr -d "$dir" | cut -d' ' -f1)
      case "$flags" in
        *C*) ;;
        *)
          echo "$dir is not NOCOW (lsattr: $flags)" >&2
          exit 1
          ;;
      esac
    '';
  };

  systemd.services."microvm@" = {
    requires = [ "microvm-state.service" ];
    after = [ "microvm-state.service" ];
  };

  homeserver.notify.units = [ "microvm-state" ];

  hardware.ksm.enable = false;
  environment.etc."qemu/bridge.conf".text = lib.mkForce "";
}
