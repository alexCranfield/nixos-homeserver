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
# short scrape gap does not resolve a firing alert; a silence stops a post;
# a post that fails while Discord is down arrives once Discord is back;
# nothing new listens beyond loopback; the webhook URL never reaches the
# journal. The rules themselves, every threshold and duration, are tested
# without a VM in tests/alert-rules.nix.
#
# The subtests are split over two checks, `alerting-a` and `alerting-b`, so
# that CI (continuous integration) runs them on different runners side by
# side (#182). Both boot this same machine; `half` picks the script, and the
# few thresholds that differ (below, under `halves`). The shared helpers are
# in alerting.py, each half's subtests in alerting-a.py and alerting-b.py.
#
# What the test changes from the host, and why (deployed values untouched):
#
#  - Short `for` durations, and a low disk threshold, through
#    `homeserver.alerting.thresholds`. The alerts the test does not force
#    get a day, so that no busy spell of an emulated VM posts in the middle
#    of a subtest that counts posts.
#  - Prometheus evaluates the rules every 5 seconds, not every 15.
#  - The grace for scrape gaps (`homeserver.alerting.gapGrace`) is 45
#    seconds, not 2 minutes, and Alertmanager's group_interval is 1
#    minute, not 5. Every resolved post waits out both, and the
#    test checks about ten of them. `timing` below says how each is chosen.
#    Every other part of Alertmanager's configuration is the host's own.
{
  pkgs,
  inputs,
  lib,
  # "a" or "b": which half of the subtests to run.
  half,
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

  host = inputs.self.nixosConfigurations.nuc.config;
  hostAlertmanager = host.services.prometheus.alertmanager.configuration;

  # Seconds in a Prometheus duration of one unit, such as "15s" or "2m".
  seconds =
    d:
    let
      m = builtins.match "([0-9]+)([smh])" d;
    in
    if m == null then
      throw "tests/alerting.nix: cannot read the duration ${d}"
    else
      lib.toInt (builtins.elemAt m 0)
      * {
        s = 1;
        m = 60;
        h = 3600;
      }
      .${builtins.elemAt m 1};

  # The timings every wait in the script is derived from, in seconds, each
  # named once here and handed to the script, so that changing one cannot
  # leave a fixed sleep too short for it.
  timing = rec {
    # The host's: every exporter is scraped this often.
    scrape = seconds host.services.prometheus.globalConfig.scrape_interval;
    # The test's, set below; the host evaluates with every scrape.
    evaluation = 5;
    # The host's: a new alert's first post waits this long.
    groupWait = seconds hostAlertmanager.route.group_wait;
    # Allowance for the VM's own delays (a command, a unit starting) on top
    # of the timings above.
    slack = 10;
    # Three scrape intervals. Subtest 6's gap is one failed scrape of
    # node-exporter, so a firing alert misses the series for one scrape
    # interval, give or take an evaluation; but a VM slow to restart the
    # exporter can miss the next scrape too, about 35 seconds in all (the
    # gap seen under emulation was up to 22). The grace must be clearly
    # longer than either. Its negative control (GapControl, below) proves
    # the same gap does drop an alert without the grace.
    grace = 3 * scrape;
    # The relay's limit on one post (SEND_TIMEOUT in
    # modules/observability/alert-relay.py). One post through
    # homeserver-notify can take about 40 seconds with curl's retries.
    relaySendTimeout = 60;
    # The floor: Alertmanager gives up on a notification after
    # max(group_interval, 10 s), its context, and a post the relay completes
    # after that is sent again at the next flush, so the relay's limit must
    # fit inside it (alert-relay.py). On the host it is 5 minutes, well
    # above; the test runs at the limit itself, as before #182, and no
    # shorter. The host's webhook `timeout` of 4 minutes, which its comment
    # says is under group_interval, is over it here: in the test the
    # context, not that timeout, bounds a notification.
    groupInterval = relaySendTimeout;
    # TargetDown's `for`, as the half sets it; two sleeps watch for it.
    targetDownFor = seconds (thresholds // this.thresholds).TargetDown.for;
  };

  quiet = {
    for = "24h";
  };

  thresholds = {
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

  # What each half runs, and what it changes. Each half boots afresh, so
  # each must stand alone. Subtest 4 needs the alerts that fire from boot
  # (the gateway, DNS and the tailnet), so it runs first in half a. Half b
  # has no subtest 4, and quiets those three like any alert it does not
  # force: they would otherwise post in the middle of its first count. The
  # split follows the expected time of each subtest, OomKill's 5 minute
  # window being the longest (docs/runbooks/ci.md).
  halves = {
    a = {
      script = ./alerting-a.py;
      thresholds = { };
    };
    b = {
      script = ./alerting-b.py;
      thresholds = {
        GatewayUnreachable = quiet;
        DnsFailing = quiet;
        TailnetDisconnected = quiet;
      };
    };
  };
  this = halves.${half};
in
pkgs.testers.runNixOSTest {
  name = "alerting-${half}";
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
    # The LAN's DNS server would bind the real nuc's address, which this VM
    # doesn't have; tests/dns.nix covers it.
    homeserver.dns.listenAddresses = lib.mkForce [ ];
    # The host names the NAS's DNS server in a sops template, which this VM
    # cannot render: with the file missing, DnsNasProbeMissing would fire
    # after its 15 minutes and post into a subtest's count. tests/dns.nix
    # covers the NAS probe.
    homeserver.alerting.dnsServers.secondaryTargetsFile = lib.mkForce null;
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
    homeserver.alerting.thresholds = thresholds // this.thresholds;
    homeserver.alerting.gapGrace = "${toString timing.grace}s";
    # The host sets 15s; a plain value here would conflict with it.
    services.prometheus.globalConfig.evaluation_interval = lib.mkForce "${toString timing.evaluation}s";
    # The option is a plain attribute set, merged one level deep, so the
    # route is given whole: the host's, with one timing changed.
    services.prometheus.alertmanager.configuration = lib.mkForce (
      hostAlertmanager
      // {
        route = hostAlertmanager.route // {
          group_interval = "${toString timing.groupInterval}s";
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

  # The constants, then the helpers both halves share, then this half's
  # subtests.
  testScript = ''
    SECRET = ${builtins.toJSON secret}
    ROLE = ${builtins.toJSON role}
    GATEWAY = ${builtins.toJSON gateway}
    IMAGE = ${builtins.toJSON "${image}"}
    SCRAPE = ${toString timing.scrape}
    EVALUATION = ${toString timing.evaluation}
    GROUP_WAIT = ${toString timing.groupWait}
    GROUP_INTERVAL = ${toString timing.groupInterval}
    GRACE = ${toString timing.grace}
    SLACK = ${toString timing.slack}
    TARGET_DOWN_FOR = ${toString timing.targetDownFor}
  ''
  + builtins.readFile ./alerting.py
  + builtins.readFile this.script;
}
