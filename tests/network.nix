# Acceptance test for ticket 1.4 (#11): the nuc takes its reserved address on
# the right port, answers to nuc.home.arpa, and shows nothing open to the LAN
# (local area network); SSH closed there in ticket 1.7 (#14).
#
# Two VMs (virtual machines). `nuc` runs the real host configuration with two
# network ports, standing in for the I226-V and the I226-LM. `router` stands in
# for the UniFi Dream Router 7: dnsmasq hands out a DHCP (Dynamic Host
# Configuration Protocol) reservation by MAC (hardware) address and answers DNS
# (Domain Name System) queries for home.arpa with the names DHCP clients send.
# It is also the machine on the LAN that scans the nuc.
#
# The real MAC addresses are replaced by the VM ports' addresses; everything
# else about the nuc's network is as it will run.
#
# What it does not cover: the real router, which is checked by hand (see
# docs/runbooks/network.md), and IPv6.
{
  pkgs,
  inputs,
  lib,
}:
let
  reservedIp = "192.168.1.50";
  # QEMU's (Quick Emulator's) address for a test VM's port: 52:54:00:12, then
  # the network number and the machine number, two hex digits each. As in
  # nixpkgs' nixos/lib/qemu-common.nix.
  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";
in
pkgs.testers.runNixOSTest {
  name = "network";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc =
    { config, ... }:
    let
      n = config.virtualisation.test.nodeNumber;
    in
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

      # Two ports, on separate networks, with no address from the test
      # framework: the nuc must configure itself. Network 1 is the LAN.
      virtualisation.interfaces = {
        eth1.vlan = 1;
        eth2.vlan = 2;
      };
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (testMac 1 n);
      systemd.network.networks."10-unused".matchConfig.PermanentMACAddress = lib.mkForce (testMac 2 n);

      # A listener the firewall should hide, for the scan to not find.
      systemd.services.probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080";
      };
    };

  nodes.router =
    { nodes, ... }:
    {
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          # The reservation: this MAC address always gets this address. No name
          # is set here, so nuc.home.arpa resolving shows the nuc sent its own.
          dhcp-range = "192.168.1.100,192.168.1.200,1h";
          dhcp-host = "${testMac 1 nodes.nuc.virtualisation.test.nodeNumber},${reservedIp}";
          domain = "home.arpa";
          local = "/home.arpa/";
          expand-hosts = true;
        };
      };
      networking.firewall.allowedUDPPorts = [
        53
        67
      ];
      environment.systemPackages = [
        pkgs.nmap
        pkgs.dig
      ];
    };

  testScript = ''
    RESERVED_IP = ${builtins.toJSON reservedIp}
  ''
  + builtins.readFile ./network.py;
}
