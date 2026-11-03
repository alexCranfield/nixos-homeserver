# Test for ticket 6.7 (#197): the tenant VMs (virtual machines) reach the
# internet and Blocky, and nothing else; ADR (Architecture Decision Record)
# 0013.
#
# CI (continuous integration) cannot boot the microVMs themselves: they would
# be a VM inside the test VM, unaccelerated. Each one is stood in for by a
# network namespace behind a veth pair whose host end has the tap's own name,
# `vm-tenant-dev` and `vm-tenant-run`. The host side is the real thing:
# networkd configures the stand-ins' links from the same units it would give
# the taps, and the same firewall, NAT (network address translation) and
# `tenant-isolation` rules apply.
#
# Four VMs on two networks:
#
#  - `nuc` runs the real host configuration on network 1, the LAN (local area
#    network), at its real address 192.168.1.131, with three things a tenant
#    must not reach: a port opened on purpose to every interface, a Docker
#    published port, and the other stand-in.
#  - `lan`, a LAN device with a web server.
#  - `router`, the default gateway at 192.168.1.1, with a web server and a
#    DNS server (dnsmasq) knowing one LAN name, as the real router does. Its
#    public (WAN) address is 203.0.113.1, where the web server answers too, as
#    the real router's console does from the LAN. It also answers on
#    100.100.100.100, in the shared address space (100.64/10) the tailnet
#    uses; Tailscale reserves that address for its own service, so it is
#    never a real device's. Unbound forwards everything to it, since the test
#    has no internet.
#  - `internet`, on network 2, a web server at 203.0.113.10 (TEST-NET-3,
#    reserved for documentation, so not in the table's closed set).
#
# The specialisation `isolationOff` is the negative control: the same host
# without the table, from which the stand-ins do reach what was blocked.
{
  pkgs,
  inputs,
  lib,
}:
let
  nucIp = "192.168.1.131";
  routerIp = "192.168.1.1";
  lanIp = "192.168.1.50";
  internetIp = "203.0.113.10";
  routerWanIp = "203.0.113.1";
  sharedIp = "100.100.100.100";
  openPort = 8081;
  publishedPort = 8082;

  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";

  # A web server on port 80 answering any address, as each target.
  web = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    systemd.services.web = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.busybox}/bin/httpd -f -p 80 -h /etc";
    };
  };

  # As in tests/game-access.nix: built by Nix and loaded by a test-only unit,
  # since the build sandbox has no internet.
  image = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "probe-root";
      paths = [ pkgs.busybox ];
    };
    config.Cmd = [
      "httpd"
      "-f"
      "-p"
      "8080"
      "-h"
      "/etc"
    ];
  };

  adsList = pkgs.writeText "tenant-net-ads.txt" "ad.test\n";
  threatsList = pkgs.writeText "tenant-net-threats.txt" "threat.test\n";
  # The LAN Blocky's private hosts file, a sops secret on the real machine.
  privateHosts = pkgs.writeText "tenant-net-private-hosts" ''
    192.168.1.88 secret-host.home.arpa
  '';
in
pkgs.testers.runNixOSTest {
  name = "tenant-net";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc =
    { config, ... }:
    {
      imports = [
        ../hosts/nuc
        # No sops secret here; the notifier posts to a sink.
        ./notify-sink.nix
        (import ./grafana-password.nix { inherit pkgs; }).module
      ];
      virtualisation.memorySize = 3072;
      virtualisation.diskSize = 4096;
      virtualisation.emptyDiskImages = [ 1024 ];

      # As in tests/tailscale.nix: one LAN port, renamed lan0 as on the real
      # machine, at the real address, so Blocky binds where it does there.
      virtualisation.interfaces.eth1.vlan = 1;
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (
        testMac 1 config.virtualisation.test.nodeNumber
      );
      systemd.network.networks."10-lan" = {
        networkConfig.DHCP = lib.mkForce "no";
        address = [ "${nucIp}/24" ];
        gateway = [ routerIp ];
      };

      # No secret can be decrypted here, and switching to the specialisation
      # below would fail trying.
      system.activationScripts.setupSecrets = lib.mkForce "";
      services.tailscale.authKeyFile = lib.mkForce null;

      # Blocky with local lists, and every kind of LAN name the real one
      # answers: a local record, the private hosts file and, through the
      # router, the DHCP (Dynamic Host Configuration Protocol) devices.
      homeserver.network.router = routerIp;
      homeserver.dns = {
        lists = lib.mkForce {
          ads = [ "${adsList}" ];
          threats = [ "${threatsList}" ];
        };
        records."probe.home.arpa" = [ "192.0.2.7" ];
        privateHostsFile = lib.mkForce "/run/tenant-net/private-hosts";
      };
      systemd.tmpfiles.rules = [
        "d /run/tenant-net 0700 root root -"
        "C /run/tenant-net/private-hosts 0400 root root - ${privateHosts}"
      ];
      # As in tests/dns.nix: Unbound asks the router, as there is no internet.
      services.unbound = {
        settings.forward-zone = lib.mkForce [
          {
            name = ".";
            forward-addr = routerIp;
          }
        ];
        enableRootTrustAnchor = lib.mkForce false;
        settings.server.local-zone = [ ''"test." nodefault'' ];
      };
      services.blocky.settings.specialUseDomains.enable = false;

      # The router's public address, which the real machine looks up.
      homeserver.tenants.routerWanCommand = "echo ${routerWanIp}";

      # A port opened to every interface, as a careless later change might.
      networking.firewall.allowedTCPPorts = [ openPort ];
      systemd.services.open-port = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.busybox}/bin/httpd -f -p ${toString openPort} -h /etc";
      };

      # Only the test's stack, published on the LAN like any public port.
      homeserver.stacks = lib.mkForce {
        probe = {
          composeFile = pkgs.writeText "compose.yml" ''
            services:
              server:
                image: probe:test
                pull_policy: never
                ports:
                  - "0.0.0.0:${toString publishedPort}:8080"
          '';
          services = [ "server" ];
          publicPorts = [ { port = publishedPort; } ];
          after = [ "test-setup.service" ];
        };
      };
      systemd.services.test-setup = {
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" ];
        wants = [ "docker.service" ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        path = [ pkgs.docker ];
        script = "docker load < ${image}";
      };

      # The VM state directory on a btrfs disk, as on the real machine, where
      # it is under / on btrfs. The test VM's own root isn't btrfs. Formatted
      # on first boot as in tests/stack-data.nix.
      microvm.stateDir = "/srv/microvms";
      systemd.services.test-format = {
        wantedBy = [ "local-fs-pre.target" ];
        before = [ "local-fs-pre.target" ];
        after = [ "dev-vdb.device" ];
        requires = [ "dev-vdb.device" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        path = [
          pkgs.btrfs-progs
          pkgs.util-linux
        ];
        script = ''
          if ! blkid /dev/vdb; then
            mkfs.btrfs -L test-data /dev/vdb
          fi
        '';
      };
      virtualisation.fileSystems."/srv" = {
        device = "/dev/disk/by-label/test-data";
        fsType = "btrfs";
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.dnsutils
        pkgs.e2fsprogs
      ];

      # Negative control: the host without the tenant table.
      specialisation.isolationOff.configuration.networking.nftables.tables.tenant-isolation.enable =
        false;
    };

  nodes.router = lib.mkMerge [
    web
    {
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = routerIp;
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = routerWanIp;
          prefixLength = 24;
        }
        {
          address = sharedIp;
          prefixLength = 32;
        }
      ];
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      networking.firewall.allowedUDPPorts = [ 53 ];
      networking.firewall.allowedTCPPorts = [ 53 ];
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          # A public name, for the tenants' Blocky to resolve.
          address = [ "/ok.test/198.51.100.7" ];
          # A DHCP device's name, as the real router knows them.
          host-record = [ "lan.home.arpa,${lanIp}" ];
        };
      };
    }
  ];

  nodes.lan = lib.mkMerge [
    web
    {
      virtualisation.vlans = [ 1 ];
      environment.systemPackages = [ pkgs.dnsutils ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = lanIp;
          prefixLength = 24;
        }
      ];
    }
  ];

  nodes.internet = lib.mkMerge [
    web
    {
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = internetIp;
          prefixLength = 24;
        }
      ];
      # Replies to the nuc, which masquerades the tenants as itself.
      networking.interfaces.eth1.ipv4.routes = [
        {
          address = "192.168.1.0";
          prefixLength = 24;
          via = routerWanIp;
        }
      ];
    }
  ];

  testScript = ''
    NUC_IP = ${builtins.toJSON nucIp}
    ROUTER_IP = ${builtins.toJSON routerIp}
    LAN_IP = ${builtins.toJSON lanIp}
    INTERNET_IP = ${builtins.toJSON internetIp}
    SHARED_IP = ${builtins.toJSON sharedIp}
    ROUTER_WAN_IP = ${builtins.toJSON routerWanIp}
    OPEN_PORT = ${toString openPort}
    PUBLISHED_PORT = ${toString publishedPort}
    BUSYBOX = "${pkgs.busybox}/bin/busybox"
  ''
  + builtins.readFile ./tenant-net.py;
}
