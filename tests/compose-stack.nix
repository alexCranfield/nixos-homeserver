# Test for ticket 3.2 (#23): a stack declared with `homeserver.stacks`
# becomes a systemd unit that runs its compose file, keeps its containers in
# a slice with the stack's limits, survives a Docker restart, and restarts
# alone when its own files change.
#
# `nuc` runs the real host configuration with three stacks from this file:
# `fixture`, with an env secret and a memory limit; `other`, which must be
# left alone when `fixture` changes; and `unbound`, not started at boot. The
# build sandbox has no internet and no age key, so the image is built by Nix
# and loaded by a test-only unit, and the env secret is written by another
# in place of sops-nix (the wiring to sops-nix's restart is asserted from the
# configuration instead). Specialisations, variants built alongside the host
# that the test switches to, change one thing each.
{
  pkgs,
  inputs,
  lib,
}:
let
  # A web server on 8080 that answers with its own name, from busybox, as in
  # tests/docker.nix.
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

  # `extra` changes the file without changing what it publishes.
  fixtureCompose =
    extra:
    pkgs.writeText "compose.yml" ''
      services:
        web:
          image: probe:test
          pull_policy: never
          env_file: .env
          environment:
            EXTRA: "${extra}"
          ports:
            - "0.0.0.0:8081:8080"
            - "8082:8080"
            - "0.0.0.0:8083:8080"
    '';

  stacks = {
    fixture = {
      composeFile = fixtureCompose "one";
      services = [ "web" ];
      envSecret = "fixture-env";
      publicPorts = [ { port = 8081; } ];
      resources.memoryMax = "64M";
      after = [ "test-setup.service" ];
    };
    other = {
      composeFile = pkgs.writeText "compose.yml" ''
        services:
          web:
            image: probe:test
            pull_policy: never
            ports:
              - "127.0.0.1:8085:8080"
      '';
      services = [ "web" ];
      after = [ "test-setup.service" ];
    };
    unbound = {
      composeFile = pkgs.writeText "compose.yml" ''
        services:
          web:
            image: probe:test
            pull_policy: never
      '';
      services = [ "web" ];
      publicPorts = [ { port = 8090; } ];
      autoStart = false;
      after = [ "test-setup.service" ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "compose-stack";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc = {
    imports = [ ../hosts/nuc ];
    virtualisation.vlans = [ 1 ];
    # As in tests/docker.nix: no secret can be decrypted here.
    services.tailscale.authKeyFile = lib.mkForce null;
    system.activationScripts.setupSecrets = lib.mkForce "";
    # The test's LAN interface stands in for lan0.
    homeserver.publicInterface = "eth1";
    environment.systemPackages = [ pkgs.curl ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    # The test driver makes any out-of-memory kill panic the VM (nixpkgs'
    # test-instrumentation.nix), including one inside a cgroup, which the
    # memory limit subtest causes on purpose. The nuc leaves it at 0.
    boot.kernel.sysctl."vm.panic_on_oom" = 0;

    # Never decrypted (above); declared so the stack can name it.
    sops.secrets.fixture-env.sopsFile = ../secrets/test.yaml;
    homeserver.stacks = stacks;

    # What the registry and sops-nix do on the real host.
    systemd.services.test-setup = {
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      path = [ pkgs.docker ];
      script = ''
        docker load < ${image}
        install -d -m 751 /run/secrets
        printf 'GREETING=one\n' > /run/secrets/fixture-env
        chmod 400 /run/secrets/fixture-env
      '';
    };

    specialisation.changed.configuration.homeserver.stacks.fixture.composeFile = lib.mkForce (
      fixtureCompose "two"
    );
    specialisation.withoutOther.configuration.homeserver.stacks = lib.mkForce (
      builtins.removeAttrs stacks [ "other" ]
    );
  };

  nodes.client = {
    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript =
    { nodes, ... }:
    ''
      NUC = "${nodes.nuc.networking.primaryIPAddress}"
      ENV_RESTARTS = ${builtins.toJSON nodes.nuc.sops.secrets.fixture-env.restartUnits}
    ''
    + builtins.readFile ./compose-stack.py;
}
