# Test for ticket 4.0 (#135): friends reach a game port over the tailnet, and
# nothing else on the nuc; nobody reaches it from the LAN (ADR 0011).
#
# Four VMs (virtual machines) on two networks:
#
#  - `nuc` runs the real host configuration on network 1, the LAN (local area
#    network), with one stack: a stand-in game server on 25565, declared with
#    `interface = "tailscale0"` as a game stack is.
#  - `friend`, on network 2, stands in for a friend the nuc is shared with.
#    Headscale has no machine sharing, so the friend is a user of the test
#    tailnet limited by the same rule the real policy gives share recipients
#    (`autogroup:shared`): the game port and nothing else.
#  - `member`, on the LAN, stands in for one of Alex's own devices: SSH and
#    the game port over the tailnet, as the real policy's `autogroup:member`
#    rule allows.
#  - `headscale` stands in for Tailscale's own servers (tests/headscale.nix).
#
# The stand-in game is busybox's web server, so a connection is one HTTP
# (Hypertext Transfer Protocol) request. Specialisations, variants built
# alongside the host that the test switches to, are the negative controls.
{
  pkgs,
  inputs,
  lib,
}:
let
  lanIp = "192.168.1.50";
  gamePort = 25565;
  headscale = import ./headscale.nix { inherit pkgs; };
  inherit (headscale) trustCert;

  # As in tests/compose-stack.nix: built by Nix and loaded by a test-only
  # unit, since the build sandbox has no internet.
  image = pkgs.dockerTools.buildImage {
    name = "game";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "game-root";
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

  game = interface: {
    composeFile = pkgs.writeText "compose.yml" ''
      services:
        server:
          image: game:test
          pull_policy: never
          ports:
            - "0.0.0.0:${toString gamePort}:8080"
    '';
    services = [ "server" ];
    publicPorts = [
      {
        port = gamePort;
        inherit interface;
      }
    ];
    after = [ "test-setup.service" ];
  };

  # QEMU's address for a test VM's port, as in tests/network.nix.
  testMac =
    net: machine:
    "52:54:00:12:${lib.fixedWidthString 2 "0" (toString net)}:${
      lib.fixedWidthString 2 "0" (toString machine)
    }";

  tailnetClient = vlan: {
    imports = [ trustCert ];
    virtualisation.vlans = [ vlan ];
    services.tailscale.enable = true;
    environment.systemPackages = [
      pkgs.curl
      pkgs.nmap
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "game-access";
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
        trustCert
      ];
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;

      # As in tests/tailscale.nix: one LAN port, renamed lan0 as on the real
      # machine, so `homeserver.publicInterface` keeps its real value.
      virtualisation.interfaces.eth1.vlan = 1;
      systemd.network.links."10-lan".matchConfig.PermanentMACAddress = lib.mkForce (
        testMac 1 config.virtualisation.test.nodeNumber
      );
      systemd.network.networks."10-lan" = {
        networkConfig.DHCP = lib.mkForce "no";
        address = [ "${lanIp}/24" ];
      };

      # As in tests/tailscale.nix: a Headscale key in place of the sops
      # secret, and autoconnect started by the test once the key is written.
      services.tailscale.authKeyFile = lib.mkForce "/run/ts-authkey";
      systemd.services.tailscaled-autoconnect.wantedBy = lib.mkForce [ ];
      services.tailscale.extraUpFlags = [ "--login-server=https://headscale" ];
      # As in tests/compose-stack.nix: no secret can be decrypted here, and
      # switching to the specialisation below would fail trying.
      system.activationScripts.setupSecrets = lib.mkForce "";

      # Only the test's stack: the host's pull images, and there is no
      # internet.
      homeserver.stacks = lib.mkForce { game = game "tailscale0"; };
      systemd.services.test-setup = {
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" ];
        wants = [ "docker.service" ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        path = [ pkgs.docker ];
        script = "docker load < ${image}";
      };

      # Negative control: the port back on the LAN, as before ADR 0011.
      specialisation.onLan.configuration.homeserver.stacks = lib.mkOverride 10 {
        game = game "lan0";
      };
    };

  nodes.friend = tailnetClient 2;
  nodes.member = tailnetClient 1;
  nodes.headscale = headscale.node;

  testScript = ''
    LAN_IP = ${builtins.toJSON lanIp}
    GAME_PORT = ${toString gamePort}
  ''
  + builtins.readFile ./game-access.py;
}
