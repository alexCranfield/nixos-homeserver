# What every tenant VM (virtual machine) is, ticket 6.8 (#198); ADR
# (Architecture Decision Record) 0013. The host declares each VM from this
# (./default.nix); ./network.nix and ./dns.nix are the host's side.
#
# A microvm.nix guest on qemu (cloud-hypervisor can't pass systemd
# credentials, which is how a VM gets its secrets):
#
#  - The root is tmpfs: everything outside /var is rebuilt at every boot from
#    the configuration. /var is an ext4 volume, an image file in the host's
#    /var/lib/microvms/<name>/, and holds all that persists: the SSH host
#    keys (/var/lib/ssh), the journal, and later Docker and the tenant's work.
#  - The host's /nix/store is shared read-only over virtiofs, so a VM's
#    software costs no disk of its own and a deploy updates it.
#  - Its one network port is the tap ./network.nix routes: a static address,
#    the host as gateway, and the tenants' own Blocky (./dns.nix) as DNS.
#  - Secrets arrive as systemd credentials. The host names a file per
#    credential (`microvm.credentialFiles`), qemu passes it in, and systemd in
#    the guest keeps it in /run/credentials/@system, readable by root alone; a
#    unit reads one with `LoadCredential=`, which gives that unit alone a copy.
#    No sops inside the VM: nothing secret is in its configuration or its
#    store. `tenant-credential-check` shows the path works with a harmless
#    one, `probe`, until the tickets that bring real secrets (6.9, 6.10).
#
# Alex reaches a VM over SSH as `ops` from the nuc only (`ssh -J ops@nuc
# ops@10.88.0.<index>`); the VM's firewall opens 22 to the host's address
# alone.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.guest;
  address = "${cfg.subnet}.${toString cfg.index}";
  hostAddress = "${cfg.subnet}.1";
in
{
  imports = [ ../base/ssh.nix ];

  options.homeserver.guest = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "The VM's name, also its host name and its tap's suffix.";
    };
    index = lib.mkOption {
      type = lib.types.ints.between 2 254;
      description = "The VM's number on the tenant network.";
    };
    subnet = lib.mkOption {
      type = lib.types.str;
      description = "The tenant network's first three octets.";
    };
    varSize = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Size of the /var volume, in MiB.";
    };
  };

  config = {
    networking.hostName = cfg.name;
    system.stateVersion = "26.05";

    microvm = {
      hypervisor = "qemu";
      shares = [
        {
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          # virtiofsd runs as root on the host; `--readonly` makes it refuse
          # writes itself. Without it only the host's own read-only mount
          # of the store stood between a guest's root (the tenant has sudo
          # in tenant-dev) and store paths the host runs as root.
          readOnly = true;
        }
      ];
      volumes = [
        {
          # Relative: under the VM's own directory in the host's state
          # directory, a NOCOW btrfs subvolume (./state.nix).
          image = "var.img";
          mountPoint = "/var";
          size = cfg.varSize;
        }
      ];
      interfaces = [
        {
          type = "tap";
          id = "vm-${cfg.name}";
          # Locally administered, numbered like the address.
          mac = "02:00:00:88:00:${lib.fixedWidthString 2 "0" (lib.toHexString cfg.index)}";
        }
      ];
      # Harmless, and the one credential until 6.9 and 6.10: proves the path
      # from the host into a unit, and who can read it on the way.
      credentialFiles.probe = pkgs.writeText "tenant-credential-probe" "not a secret\n";
    };

    # The tap, matched by its MAC (hardware) address, as in microvm.nix's
    # "routed network" page.
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks."10-tap" = {
      matchConfig.MACAddress = (lib.head config.microvm.interfaces).mac;
      address = [ "${address}/32" ];
      routes = [
        {
          Destination = "${hostAddress}/32";
          GatewayOnLink = true;
        }
        {
          Destination = "0.0.0.0/0";
          Gateway = hostAddress;
          GatewayOnLink = true;
        }
      ];
      networkConfig = {
        DNS = [ hostAddress ];
        # IPv4 only, like the host's side of the tap.
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
    };

    # SSH from the host alone. modules/base/ssh.nix keeps its keys in
    # /etc/ssh, which is tmpfs here; in /var they survive a restart.
    services.openssh.hostKeys = lib.mkForce [
      {
        path = "/var/lib/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    networking.firewall.enable = true;
    networking.nftables.enable = true;
    networking.firewall.extraInputRules = ''
      ip saddr ${hostAddress} tcp dport 22 accept
    '';

    systemd.services.tenant-credential-check = {
      description = "Read the probe credential, as a service with a secret would";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = "probe";
        ExecStart = "${pkgs.coreutils}/bin/cat %d/probe";
      };
    };

    # For the checks in `just tenant-smoke` (docs/runbooks/tenants.md).
    environment.systemPackages = [
      pkgs.curl
      pkgs.dnsutils
      pkgs.netcat-openbsd
    ];
  };
}
