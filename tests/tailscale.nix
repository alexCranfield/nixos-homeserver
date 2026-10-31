# Acceptance test for ticket 1.5 (#12): ops logs in to the nuc over the tailnet
# from another network, and the tailnet sees only SSH. Since ticket 3.4 (#25)
# it also sees Grafana, published by Tailscale Serve, which the access policy
# can close.
#
# Three VMs (virtual machines) on two networks:
#
#  - `nuc` runs the real host configuration, on network 1, the LAN (local area
#    network).
#  - `client` stands in for the workstation on a phone hotspot: network 2, with
#    no route to network 1.
#  - `headscale` stands in for Tailscale's own servers (tests/headscale.nix).
#
# The real tailnet cannot be used: the build sandbox has no internet, and a
# test must not hold a real auth key. What differs from the real thing: the
# login server (`--login-server`), and the auth key, which the test writes to a
# file in place of the sops secret the real host reads. The access policy is
# Headscale's form of the real one (tests/tailscale.py).
{
  pkgs,
  inputs,
  lib,
}:
let
  lanIp = "192.168.1.50";
  # `+`, not "${pkgs.path}/…": interpolating copies all of nixpkgs into the
  # store, which `nix flake check --no-build` cannot do on a cold store (#141).
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  headscale = import ./headscale.nix { inherit pkgs; };
  inherit (headscale) trustCert;
  # QEMU's address for a test VM's port, as in tests/network.nix.
  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";
in
pkgs.testers.runNixOSTest {
  name = "tailscale";
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
        (import ./grafana-password.nix { inherit pkgs; }).module
        trustCert
      ];
      # The host's stacks pull images, and the build sandbox has no internet;
      # tests/compose-stack.nix covers them.
      homeserver.stacks = lib.mkForce { };
      # Grafana, Prometheus, PostgreSQL and Blocky's list loads boot together
      # on this host. On one emulated CPU (central processing unit) they slow
      # the boot enough that tailscaled-autoconnect times out before the nuc
      # has joined the tailnet. As in tests/dns.nix.
      virtualisation.cores = 4;

      # One port on the LAN, renamed lan0 as on the real machine, with a fixed
      # address in place of the router's reservation (tests/network.nix covers
      # DHCP).
      virtualisation.interfaces.eth1.vlan = 1;
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (
        testMac 1 config.virtualisation.test.nodeNumber
      );
      systemd.network.networks."10-lan" = {
        networkConfig.DHCP = lib.mkForce "no";
        address = [ "${lanIp}/24" ];
      };
      # The LAN's DNS server on this address, in place of the real one, so the
      # test can show port 53 is open on the LAN and closed on the tailnet.
      homeserver.dns.listenAddresses = lib.mkForce [ lanIp ];
      # The host points this at its sops secret (hosts/nuc/dns.nix), which a
      # test VM cannot decrypt; without the file, Blocky's LoadCredential fails
      # and it never opens port 53. tests/dns.nix covers the private names.
      homeserver.dns.privateHostsFile = lib.mkForce null;

      # The host points this at its sops secret (hosts/nuc/tailscale.nix), which
      # a test VM cannot decrypt. The test writes a Headscale key here instead.
      services.tailscale.authKeyFile = lib.mkForce "/run/ts-authkey";
      # Not started at boot: the key does not exist yet, and a boot-time start
      # runs `tailscale up` with no key, which waits at a login URL. Racing the
      # test's own start against it made the test flaky in CI (continuous
      # integration, #103). The test starts it once the key is written, as on
      # the real host, where sops-nix writes it at activation, before services
      # start.
      systemd.services.tailscaled-autoconnect.wantedBy = lib.mkForce [ ];
      services.tailscale.extraUpFlags = [ "--login-server=https://headscale" ];

      users.users.ops.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];

      # A listener the firewall should hide from the tailnet.
      systemd.services.probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080";
      };
    };

  nodes.client = {
    imports = [ trustCert ];
    virtualisation.vlans = [ 2 ];
    services.tailscale.enable = true;
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
      pkgs.nmap
    ];
  };

  nodes.headscale = {
    imports = [ headscale.node ];
    # For the DNS check from the LAN (tests/tailscale.py).
    environment.systemPackages = [ pkgs.dig ];
  };

  testScript = ''
    LAN_IP = ${builtins.toJSON lanIp}
    SNAKEOIL_KEY = ${builtins.toJSON "${keys.snakeOilPrivateKey}"}
    GRAFANA_PASSWORD = ${builtins.toJSON (import ./grafana-password.nix { inherit pkgs; }).password}
  ''
  + builtins.readFile ./tailscale.py;
}
