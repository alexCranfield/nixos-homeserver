# Test for ticket 3.1 (#22): Docker publishes ports on loopback unless told
# otherwise, and nobody gets the `docker` group.
#
# One VM (virtual machine) runs the real host configuration. The build sandbox
# has no internet, so the container image is built by Nix and loaded, not
# pulled. Two specialisations, variants built alongside the host that the test
# switches to, are the negative controls: `noIp` sets the daemon's `ip` back to
# Docker's default, and `noNetworkDefault` empties `default-network-opts`. Each
# must make the matching case bind to every interface, which shows the check
# would catch the setting going missing.
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
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc = {
    imports = [ ../hosts/nuc ];
    # As in reboot-window.nix: no secret can be decrypted here, and the test
    # switches configuration, which would report it.
    services.tailscale.authKeyFile = lib.mkForce null;
    system.activationScripts.setupSecrets = lib.mkForce "";
    # For the test script only; the host has no curl of its own.
    environment.systemPackages = [ pkgs.curl ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    specialisation.noIp.configuration.virtualisation.docker.daemon.settings.ip = lib.mkForce "0.0.0.0";
    specialisation.noNetworkDefault.configuration.virtualisation.docker.daemon.settings.default-network-opts =
      lib.mkForce { };
  };

  testScript = ''
    IMAGE = "${image}"
    COMPOSE = "${compose}"
  ''
  + builtins.readFile ./docker.py;
}
