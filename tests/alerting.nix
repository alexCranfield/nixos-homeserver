# End-to-end test for ticket #27: an alert condition on the host becomes one
# post in the alerts channel, and its end one more.
#
# One VM (virtual machine) runs the real host configuration and the whole
# pipeline: Prometheus evaluates the rules, Alertmanager groups and inhibits,
# the relay posts through homeserver-notify. Discord is replaced by the
# webhook receiver of tests/notify.nix, which stores each request body in the
# driver's shared directory.
#
# What it proves, for the alerts it forces (TargetDown, UnitFailed,
# DiskFilling, GatewayUnreachable, DnsFailing, TailnetDisconnected, OomKill,
# StackMemoryNearLimit): each posts once with its summary, pinging the role,
# and posts once more, without a ping, when its condition clears; a dead
# gateway holds back the alerts it causes; a unit the notifier watches posts
# once, not twice; a resolved alert does not re-post one still firing; a
# silence stops a post; a post that fails while Discord is down arrives once
# Discord is back; nothing new listens beyond loopback; the webhook URL never
# reaches the journal. The rules themselves, every threshold and duration,
# are tested without a VM in tests/alert-rules.nix.
#
# What the test changes from the host, and why (deployed values untouched):
#
#  - Short `for` durations, and a low disk threshold, through
#    `homeserver.alerting.thresholds`. The alerts the test does not force
#    get a day, so that no busy spell of an emulated VM posts in the middle
#    of a subtest that counts posts.
#  - Prometheus evaluates the rules every 5 seconds, not every minute.
#  - Alertmanager's group_interval is 1 minute, not 5: it is how long a
#    resolved post waits after the firing one. Every other part of
#    Alertmanager's configuration is the host's own.
{
  pkgs,
  inputs,
  lib,
}:
let
  port = 8099;
  secret = "token-that-must-not-be-logged";
  url = "http://127.0.0.1:${toString port}/api/webhooks/1/${secret}";
  role = "123456789012345678";
  # An address in the LAN's range that nothing answers, until the test puts
  # it on the VM's own loopback.
  gateway = "192.168.1.254";

  receiver = pkgs.writers.writePython3 "webhook-receiver" { } ''
    import http.server
    import pathlib

    out = pathlib.Path("/tmp/shared/webhook")
    out.mkdir(exist_ok=True)


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            n = len(list(out.glob("*.json")))
            # Written whole under a temporary name, so a reader never sees a
            # partial message.
            (out / f"{n:03}.tmp").write_bytes(body)
            (out / f"{n:03}.tmp").rename(out / f"{n:03}.json")
            self.send_response(204)
            self.end_headers()

        # The path holds the token, and the receiver stands in for Discord,
        # whose logs are not the host's.
        def log_message(self, format, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';

  # A stand-in for a stack's container, as in tests/observability.nix: the
  # build sandbox has no internet to pull an image.
  image = pkgs.dockerTools.buildImage {
    name = "oomtest";
    tag = "test";
    copyToRoot = pkgs.busybox;
    config.Cmd = [
      "sleep"
      "1000000"
    ];
  };

  hostAlertmanager =
    inputs.self.nixosConfigurations.nuc.config.services.prometheus.alertmanager.configuration;

  quiet = {
    for = "24h";
  };
in
pkgs.testers.runNixOSTest {
  name = "alerting";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;
  # Under emulation (TCG, QEMU's software emulation, no KVM) the run takes
  # longer than the driver's default hour.
  globalTimeout = 3 * 3600;

  nodes.nuc = {
    imports = [
      ../hosts/nuc
      (import ./grafana-password.nix { inherit pkgs; }).module
    ];
    virtualisation.memorySize = 2048;
    # Test only: the VM's LAN port has no DHCP (Dynamic Host Configuration
    # Protocol) server, so waiting for the network times out and leaves a
    # failed unit, whose UnitFailed post would land in whichever subtest is
    # counting posts at the time. On the nuc the router answers.
    systemd.network.wait-online.enable = false;
    # The host's stacks pull images, and the build sandbox has no internet.
    homeserver.stacks = lib.mkForce { };
    # As in tests/notify.nix: the sops secrets cannot be decrypted here.
    services.tailscale.authKeyFile = lib.mkForce null;
    system.activationScripts.setupSecrets = lib.mkForce "";
    homeserver.notify.webhookFile = lib.mkForce "/run/notify-test/webhook";
    homeserver.notify.roleFile = lib.mkForce "/run/notify-test/role";
    homeserver.announce.webhookFile = lib.mkForce null;
    systemd.tmpfiles.rules = [
      "C /run/notify-test/webhook 0400 root root - ${pkgs.writeText "webhook" url}"
      "C /run/notify-test/role 0400 root root - ${pkgs.writeText "role" role}"
    ];
    systemd.services.notify-online.after = [ "webhook-receiver.service" ];
    systemd.services.webhook-receiver = {
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = "/tmp/shared";
      serviceConfig.ExecStart = receiver;
    };

    homeserver.alerting.gateway = gateway;
    homeserver.alerting.thresholds = {
      # Long enough for node-exporter to report a killed cAdvisor as failed
      # (both are scraped every 15 seconds) before cAdvisor's TargetDown
      # fires.
      TargetDown.for = "30s";
      # The gateway's alert fires before the two it inhibits, so that
      # neither posts before the inhibition is in place. 45 seconds apart is
      # enough only because Prometheus starts once Alertmanager is ready
      # (modules/observability/alerting.nix): before that ordering, the
      # gateway's first firing was refused, sent again a minute later, and
      # DnsFailing posted in between.
      GatewayUnreachable.for = "15s";
      DnsFailing.for = "60s";
      TailnetDisconnected.for = "60s";
      DiskFilling = {
        value = 50;
        for = "15s";
      };
      StackMemoryNearLimit.for = "15s";

      CominFetchFailed = quiet; # no internet here
      CominBuildFailed = quiet;
      HostMemoryLow = quiet;
      HostCpuHigh = quiet;
      TemperatureHigh = quiet;
      ContainerCpuHigh = quiet;
      StackMemoryStalled = quiet;
      StackCpuStarved = quiet;
    };
    services.prometheus.globalConfig.evaluation_interval = "5s";
    # The option is a plain attribute set, merged one level deep, so the
    # route is given whole: the host's, with one timing changed.
    services.prometheus.alertmanager.configuration = lib.mkForce (
      hostAlertmanager
      // {
        route = hostAlertmanager.route // {
          group_interval = "1m";
        };
      }
    );
    environment.systemPackages = [ pkgs.prometheus-alertmanager ]; # amtool

    # Test only: the test driver's instrumentation sets 2, which panics the
    # kernel on any out-of-memory kill, even one confined to a cgroup (seen:
    # the VM panicked in subtest 5). The nuc runs the kernel's default, 0.
    boot.kernel.sysctl."vm.panic_on_oom" = 0;

    # The negative control of subtest 6: UnitFailed for one unit, without
    # keep_firing_for, so a scrape gap drops it and it fires again as a new
    # alert. Silenced by the test, so it never posts.
    services.prometheus.ruleFiles = [
      (pkgs.writeText "gap-control.yml" (
        builtins.toJSON {
          groups = [
            {
              name = "test-gap-control";
              rules = [
                {
                  alert = "GapControl";
                  expr = ''node_systemd_unit_state{name="fail-b.service",state="failed"} == 1'';
                }
              ];
            }
          ];
        }
      ))
    ];

    # A stack's slice as modules/containers/compose-stack.nix makes one:
    # the dash puts it under stack.slice.
    systemd.slices.stack-oomtest.sliceConfig.MemoryMax = "64M";
  };

  testScript = ''
    SECRET = ${builtins.toJSON secret}
    ROLE = ${builtins.toJSON role}
    GATEWAY = ${builtins.toJSON gateway}
    IMAGE = ${builtins.toJSON "${image}"}
  ''
  + builtins.readFile ./alerting.py;
}
