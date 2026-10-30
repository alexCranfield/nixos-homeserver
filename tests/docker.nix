# Test for ticket 3.1 (#22): Docker publishes ports on loopback unless told
# otherwise, nobody gets the `docker` group, and the nuc forwards nothing it
# was not asked to.
#
# `nuc` runs the real host configuration, on two networks: the LAN (1), where
# `lan` stands in for a neighbour, and a second network (2) with `far` on it,
# standing in for anything the nuc could route to. The build sandbox
# has no internet, so the container image is built by Nix and loaded, not
# pulled. Two specialisations, variants built alongside the host that the test
# switches to, are the negative controls: `noIp` sets the daemon's `ip` to
# `0.0.0.0`, and `noNetworkDefault` empties `default-network-opts`. Each
# must make the matching case bind to every interface, which shows the check
# would catch the setting going missing. A third, `noForwardFilter`, turns
# the firewall's forward filter off, and `lan` must then reach `far` through
# the nuc. A fourth, `noLiveRestore`, turns `live-restore` off, and a daemon
# restart must then stop a container.
{
  pkgs,
  inputs,
  lib,
}:
let
  # A web server on 8080 that answers with its own name, from busybox.
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
  # A Compose project publishing a port without an address, the case the
  # network default exists for. Compose creates the project's own network.
  compose = pkgs.writeText "compose.yaml" ''
    services:
      web:
        image: probe:test
        pull_policy: never
        ports:
          - "8082:8080"
  '';
in
pkgs.testers.runNixOSTest {
  name = "docker";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc = {
    imports = [
      ../hosts/nuc
      # No sops secret here; the notifier posts to a sink.
      ./notify-sink.nix
      (import ./grafana-password.nix { inherit pkgs; }).module
    ];
    # The host's stacks pull images, and the build sandbox has no internet;
    # tests/compose-stack.nix covers them.
    homeserver.stacks = lib.mkForce { };
    # The LAN's DNS server would bind the real nuc's address, which this VM
    # doesn't have; tests/dns.nix covers it.
    homeserver.dns.listenAddresses = lib.mkForce [ ];
    virtualisation.vlans = [
      1
      2
    ];
    # As in reboot-window.nix: no secret can be decrypted here, and the test
    # switches configuration, which would report it.
    services.tailscale.authKeyFile = lib.mkForce null;
    system.activationScripts.setupSecrets = lib.mkForce "";
    # For the test script only; the host has no curl of its own.
    environment.systemPackages = [
      pkgs.curl
      pkgs.iptables
    ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    specialisation.noIp.configuration.virtualisation.docker.daemon.settings.ip = lib.mkForce "0.0.0.0";
    specialisation.noNetworkDefault.configuration.virtualisation.docker.daemon.settings.default-network-opts =
      lib.mkForce { };
    specialisation.noForwardFilter.configuration.networking.firewall.filterForward = lib.mkForce false;
    specialisation.noLiveRestore.configuration.virtualisation.docker.daemon.settings.live-restore =
      lib.mkForce false;
  };

  # A web server on each side, answering with its own name. Each routes the
  # other network through the nuc, as a neighbour trying it would.
  nodes.lan =
    { nodes, ... }:
    {
      virtualisation.vlans = [ 1 ];
      environment.systemPackages = [ pkgs.curl ];
      networking.firewall.allowedTCPPorts = [ 80 ];
      services.static-web-server = {
        enable = true;
        listen = "[::]:80";
        root = pkgs.writeTextDir "index.html" "lan";
      };
      networking.interfaces.eth1.ipv4.routes = [
        {
          address = "192.168.2.0";
          prefixLength = 24;
          via = nodes.nuc.networking.primaryIPAddress;
        }
      ];
    };
  nodes.far =
    { nodes, ... }:
    {
      virtualisation.vlans = [ 2 ];
      networking.firewall.allowedTCPPorts = [ 80 ];
      services.static-web-server = {
        enable = true;
        listen = "[::]:80";
        root = pkgs.writeTextDir "index.html" "far";
      };
      networking.interfaces.eth1.ipv4.routes = [
        {
          address = "192.168.1.0";
          prefixLength = 24;
          via = (lib.head nodes.nuc.networking.interfaces.eth2.ipv4.addresses).address;
        }
      ];
    };

  testScript =
    { nodes, ... }:
    ''
      IMAGE = "${image}"
      COMPOSE = "${compose}"
      NUC_LAN = "${nodes.nuc.networking.primaryIPAddress}"
      LAN = "${nodes.lan.networking.primaryIPAddress}"
      FAR = "${nodes.far.networking.primaryIPAddress}"
    ''
    + builtins.readFile ./docker.py;
}
