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
            - "[::]:8081:8080"
            - "8082:8080"
            - "0.0.0.0:8083:8080"
            - "0.0.0.0:8084:8084/udp"
    '';

  # Stands in for Discord, as in tests/notify.nix, keeping each post in
  # /tmp/webhook inside the VM.
  port = 8099;
  role = "123456789012345678";
  receiver = pkgs.writers.writePython3 "webhook-receiver" { } ''
    import http.server
    import pathlib

    out = pathlib.Path("/tmp/webhook")
    out.mkdir(exist_ok=True)


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            n = len(list(out.glob("*.json")))
            (out / f"{n:03}.tmp").write_bytes(body)
            (out / f"{n:03}.tmp").rename(out / f"{n:03}.json")
            self.send_response(204)
            self.end_headers()


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';

  stacks = {
    fixture = {
      composeFile = fixtureCompose "one";
      services = [ "web" ];
      envSecret = "fixture-env";
      publicPorts = [
        { port = 8081; }
        {
          port = 8084;
          protocol = "udp";
        }
      ];
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
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc = {
    imports = [
      ../hosts/nuc
      (import ./grafana-password.nix { inherit pkgs; }).module
    ];
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

    # Crash alerts go to the receiver above. Files outside the store, as
    # sops-nix would put them (modules/base/notify.nix refuses store paths).
    homeserver.notify.webhookFile = lib.mkForce "/run/notify-test/webhook";
    homeserver.notify.roleFile = lib.mkForce "/run/notify-test/role";
    systemd.tmpfiles.rules = [
      "C /run/notify-test/webhook 0400 root root - ${pkgs.writeText "webhook" "http://127.0.0.1:${toString port}/api/webhooks/1/token"}"
      "C /run/notify-test/role 0400 root root - ${pkgs.writeText "role" role}"
    ];
    systemd.services.webhook-receiver = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = receiver;
    };

    # Never decrypted (above); declared so the stack can name it.
    sops.secrets.fixture-env.sopsFile = ../secrets/test.yaml;
    # Only the test's stacks: the host's pull images, and there is no internet.
    homeserver.stacks = lib.mkForce stacks;
    # The LAN's DNS server would bind the real nuc's address, which this VM
    # doesn't have; tests/dns.nix covers it.
    homeserver.dns.listenAddresses = lib.mkForce [ ];

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

    # Each replaces the whole set, above the mkForce before it.
    specialisation.changed.configuration.homeserver.stacks = lib.mkOverride 10 (
      lib.recursiveUpdate stacks { fixture.composeFile = fixtureCompose "two"; }
    );
    specialisation.withoutOther.configuration.homeserver.stacks = lib.mkOverride 10 (
      builtins.removeAttrs stacks [ "other" ]
    );
    specialisation.withoutFixture.configuration.homeserver.stacks = lib.mkOverride 10 (
      builtins.removeAttrs stacks [ "fixture" ]
    );
    # 192.0.2.1 is a documentation address: anyone but the client.
    specialisation.restricted.configuration.homeserver.stacks = lib.mkOverride 10 (
      lib.recursiveUpdate stacks {
        fixture.publicPorts = [
          {
            port = 8081;
            allowedSources = [ "192.0.2.1/32" ];
          }
          {
            port = 8084;
            protocol = "udp";
          }
        ];
      }
    );
    # Only the unit file changes, as when a deploy moves Docker's store path.
    specialisation.unitOnly.configuration.systemd.services.stack-fixture.environment.UNIT_ONLY = "1";
    # Docker and the stack change in the same switch, as when an update moves
    # Docker's store path: Docker is stopped before the stack is reloaded.
    specialisation.dockerAndUnit.configuration = {
      systemd.services.docker.environment.UNIT_ONLY = "1";
      systemd.services.stack-fixture.environment.UNIT_ONLY = "1";
    };
    # Negative controls, as in tests/docker.nix.
    specialisation.noNetworkDefault.configuration.virtualisation.docker.daemon.settings.default-network-opts =
      lib.mkForce { };
    specialisation.noStackFirewall.configuration.networking.nftables.tables.stack-ports.enable =
      lib.mkForce false;
  };

  nodes.client = {
    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript =
    { nodes, ... }:
    ''
      NUC = "${nodes.nuc.networking.primaryIPAddress}"
      NUC6 = "${nodes.nuc.networking.primaryIPv6Address}"
      CLIENT = "${nodes.client.networking.primaryIPAddress}"
      ROLE = "${role}"
      ENV_RESTARTS = ${builtins.toJSON nodes.nuc.sops.secrets.fixture-env.restartUnits}
    ''
    + builtins.readFile ./compose-stack.py;
}
