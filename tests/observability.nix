# Acceptance test for ticket 3.4 (#25): the nuc collects its own metrics, and
# nothing that collects them is reachable from the LAN (local area network).
#
# Two VMs (virtual machines) on one network:
#
#  - `nuc` runs the real host configuration, with a fixed LAN address in place
#    of the router's reservation, and one stand-in container, `probe`, for
#    cAdvisor to find: the build sandbox has no internet to pull a real image.
#  - `lan` is another device on the LAN, which scans the nuc.
#
# The tailnet side, Grafana through Tailscale Serve, is in tests/tailscale.nix.
{
  pkgs,
  inputs,
  lib,
}:
let
  lanIp = "192.168.1.50";
  # QEMU's address for a test VM's port, as in tests/network.nix.
  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";
  image = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "test";
    copyToRoot = pkgs.busybox;
    config.Cmd = [
      "sleep"
      "1000000"
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "observability";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc =
    { config, ... }:
    {
      imports = [ ../hosts/nuc ];
      # The host's stacks pull images, and the build sandbox has no internet.
      homeserver.stacks = lib.mkForce { };
      # As in tests/announce.nix: no sops secret can be decrypted here.
      services.tailscale.authKeyFile = lib.mkForce null;
      system.activationScripts.setupSecrets = lib.mkForce "";

      # One port on the LAN, renamed lan0 as on the real machine, with a fixed
      # address, as in tests/tailscale.nix.
      virtualisation.interfaces.eth1.vlan = 1;
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (
        testMac 1 config.virtualisation.test.nodeNumber
      );
      systemd.network.networks."10-lan" = {
        networkConfig.DHCP = lib.mkForce "no";
        address = [ "${lanIp}/24" ];
      };

      systemd.services.probe = {
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        path = [ pkgs.docker ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        script = ''
          docker load < ${image}
          docker rm -f probe || true
          docker run -d --name probe probe:test
        '';
      };
    };

  nodes.lan = {
    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [ pkgs.nmap ];
  };

  testScript = ''
    LAN_IP = ${builtins.toJSON lanIp}
    PYTHON = ${builtins.toJSON "${pkgs.python3}/bin/python3"}
  ''
  + builtins.readFile ./observability.py;
}
