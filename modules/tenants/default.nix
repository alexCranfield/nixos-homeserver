# The tenant microVMs (virtual machines), ADR (Architecture Decision Record)
# 0013: a tenant's dev environment and scheduled jobs, each in its own VM,
# cut off from everything but the internet and the LAN's (local area
# network's) DNS (Domain Name System).
#
# `homeserver.tenants.vms.<name>` declares one VM. This ticket, 6.7 (#197),
# gives each its network (./network.nix) and the host its VM state directory
# (./state.nix); the VMs themselves come in 6.8 (#198). The day-to-day side is
# docs/runbooks/tenants.md.
{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.homeserver.tenants;
in
{
  imports = [
    inputs.microvm.nixosModules.host
    ./network.nix
    ./state.nix
  ];

  options.homeserver.tenants = {
    vms = lib.mkOption {
      default = { };
      description = ''
        The tenant VMs. The name must start with `tenant-` and its tap
        interface, `vm-<name>`, must fit Linux's 15-character limit.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.index = lib.mkOption {
            type = lib.types.ints.between 2 254;
            description = ''
              The VM's number on the tenant network: its address is
              `10.88.0.<index>`. Unique across VMs; 1 is the host.
            '';
          };
        }
      );
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "10.88.0";
      readOnly = true;
      description = "The tenant network's first three octets; a /24.";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.subnet}.1";
      readOnly = true;
      description = "The host's address on every tap, the VMs' gateway.";
    };
  };

  config.assertions = lib.concatLists (
    lib.mapAttrsToList (name: vm: [
      {
        assertion = lib.hasPrefix "tenant-" name;
        message = "homeserver.tenants.vms.${name}: the name must start with tenant-, which the firewall rules match on.";
      }
      {
        assertion = lib.stringLength "vm-${name}" <= 15;
        message = "homeserver.tenants.vms.${name}: the tap name vm-${name} is longer than Linux's 15 characters.";
      }
      {
        assertion = lib.length (lib.filter (v: v.index == vm.index) (lib.attrValues cfg.vms)) == 1;
        message = "homeserver.tenants.vms.${name}: index ${toString vm.index} is used by another VM.";
      }
    ]) cfg.vms
  );
}
