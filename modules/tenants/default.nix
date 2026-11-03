# The tenant microVMs (virtual machines), ADR (Architecture Decision Record)
# 0013: a tenant's dev environment and scheduled jobs, each in its own VM,
# cut off from everything but the internet and the LAN's (local area
# network's) DNS (Domain Name System).
#
# `homeserver.tenants.vms.<name>` declares one VM: its network
# (./network.nix, 6.7, #197), its DNS (./dns.nix), and the VM itself, a
# microvm.nix guest built from ./guest-base.nix plus the VM's own `modules`
# (6.8, #198). The host's VM state directory is ./state.nix. The day-to-day
# side is docs/runbooks/tenants.md.
#
# Each VM runs as `microvm@<name>.service`, limited from the host side: a
# memory ceiling of the guest's RAM plus 1 GB for qemu itself, and half the
# default CPU and I/O weights, so the game servers and the LLMs win any
# contention. A VM that fails posts to Discord.
#
# Not declared at all when this configuration is itself a VM, a test node or
# `just vm`: a VM inside it would have no KVM (Kernel-based Virtual Machine)
# to run on, and evaluating two more NixOS systems in each of the tests that
# import the host ran CI's runners out of memory (2.7 GB for the host alone,
# against 1.3 GB without them). Their network and DNS stay, which
# tests/tenant-net.nix tests; the real host's build in CI covers the VMs.
{
  config,
  options,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.homeserver.tenants;
  # True in a test node or `just vm`, which import qemu's VM module; the real
  # host doesn't.
  inVm = options.virtualisation ? qemu;
in
{
  imports = [
    inputs.microvm.nixosModules.host
    ./dns.nix
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
          options = {
            index = lib.mkOption {
              type = lib.types.ints.between 2 254;
              description = ''
                The VM's number on the tenant network: its address is
                `10.88.0.<index>`. Unique across VMs; 1 is the host.
              '';
            };
            vcpu = lib.mkOption {
              type = lib.types.ints.positive;
              default = 2;
              description = "Virtual CPU (central processing unit) cores.";
            };
            memory = lib.mkOption {
              type = lib.types.ints.positive;
              default = 4096;
              description = "The guest's RAM (random access memory), in MiB.";
            };
            varSize = lib.mkOption {
              type = lib.types.ints.positive;
              default = 30 * 1024;
              description = ''
                Size of the VM's /var volume, in MiB. Used when the image is
                first made; changing it later doesn't resize an existing one.
              '';
            };
            modules = lib.mkOption {
              type = lib.types.listOf lib.types.deferredModule;
              default = [ ];
              description = "NixOS modules for this VM, beside ./guest-base.nix.";
            };
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

    routerWanCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.curl}/bin/curl -sSf --max-time 10 https://1.1.1.1/cdn-cgi/trace | ${pkgs.gnused}/bin/sed -n 's/^ip=//p'";
      description = ''
        A shell command printing the router's public IPv4 address, which
        ./network.nix closes to the VMs. Cloudflare's trace page, asked by
        address so it doesn't depend on DNS.
      '';
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.subnet}.1";
      readOnly = true;
      description = "The host's address on every tap, the VMs' gateway.";
    };
  };

  config.microvm.vms = lib.mkIf (!inVm) (
    lib.mapAttrs (name: vm: {
      # The host's own nixpkgs, so a VM shares its store paths and its pin.
      inherit pkgs;
      specialArgs = { inherit inputs; };
      config = {
        imports = [ ./guest-base.nix ] ++ vm.modules;
        homeserver.guest = {
          inherit name;
          inherit (vm) index varSize;
          inherit (cfg) subnet;
        };
        microvm = {
          inherit (vm) vcpu;
          mem = vm.memory;
        };
      };
    }) cfg.vms
  );

  # Drop-ins on microvm.nix's templates, not whole units: a unit defined here
  # under the instance's name would replace the template's. The store's
  # file server, virtiofsd, is a unit of its own, run as root, and gets the
  # same weights and a ceiling of its own.
  config.systemd.services = lib.mkIf (!inVm) (
    lib.mkMerge (
      lib.mapAttrsToList (name: vm: {
        "microvm@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            MemoryMax = "${toString (vm.memory + 1024)}M";
            CPUWeight = 50;
            IOWeight = 50;
          };
        };
        "microvm-virtiofsd@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            MemoryMax = "1G";
            CPUWeight = 50;
            IOWeight = 50;
          };
        };
      }) cfg.vms
    )
  );

  config.homeserver.notify.units = lib.mkIf (!inVm) (
    lib.mapAttrsToList (name: _: "microvm@${name}") cfg.vms
  );

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
