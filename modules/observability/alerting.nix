# Alerting, ticket 3.6 (#27): Prometheus evaluates the rules in rules.nix,
# Alertmanager groups what fires, and a small relay posts it to Discord.
#
#  - Prometheus sends firing alerts to Alertmanager, which waits 10 seconds
#    to group alerts that start together into one notification, repeats a
#    firing one every 12 hours, and says when it resolves.
#  - Alertmanager's one receiver is a webhook to the relay below, not to
#    Discord: Discord's message format is not Alertmanager's, and posting
#    through the relay reuses homeserver-notify (modules/base/notify.nix),
#    which keeps the webhook URL off command lines and out of the journal
#    and neutralises mentions. No new secret: the relay is given the same
#    files as the failure notifier.
#  - A firing alert pings the role; a resolved one does not.
#
# Everything listens on 127.0.0.1 only, and no firewall port is opened.
# Alertmanager's cluster listener (high availability between several
# Alertmanagers, port 9094 by default) is switched off: there is one.
#
# Where there is no webhook (`homeserver.notify.webhookFile` null) Alertmanager
# and the relay are not run, and Prometheus only evaluates the rules.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.alerting;
  notify = config.homeserver.notify;
  host = config.networking.hostName;
  rules = import ./rules.nix;
  ports = {
    alertmanager = 9093;
    relay = 9095;
  };
  ruleFile = pkgs.writeText "alert-rules.yml" (
    # JSON (JavaScript Object Notation) is valid YAML (YAML Ain't Markup
    # Language), and Prometheus's rule loader reads it as such.
    builtins.toJSON (
      rules.mkRules {
        inherit lib;
        inherit (cfg) thresholds gapGrace;
        watchedUnits = notify.units;
        nasProbed = cfg.dnsServers.secondaryTargetsFile != null;
        dnsServed = config.homeserver.dns.listenAddresses != [ ];
      }
    )
  );
  enabled = notify.webhookFile != null;
  roleArg = if notify.roleFile == null then "-" else "%d/role";
in
{
  options.homeserver.alerting.thresholds = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = rules.defaults;
    defaultText = lib.literalMD "the `defaults` of `rules.nix`";
    example = {
      DiskFilling = {
        value = 50;
        for = "10s";
      };
    };
    description = ''
      Thresholds and durations of the alert rules, by alert name. Whatever is
      given is merged over `defaults` in rules.nix, a level deeper than the
      alert, so an entry need list only what it changes, and an alert left
      out keeps its default.
    '';
  };

  options.homeserver.alerting.gapGrace = lib.mkOption {
    type = lib.types.strMatching "[0-9]+[smh]";
    default = rules.gapGrace;
    defaultText = lib.literalMD "the `gapGrace` of `rules.nix`, `\"2m\"`";
    example = "30s";
    description = ''
      How long a firing alert stays firing after its series stops matching
      (Prometheus's `keep_firing_for`), so that one missed scrape does not
      post a resolve and then a new alert. Every rule but TargetDown has it,
      and every resolved post waits this long. Shortened only by the
      alerting VM test, which waits out many resolves.
    '';
  };

  config = lib.mkMerge [
    {
      services.prometheus.ruleFiles = [ ruleFile ];
    }

    (lib.mkIf enabled {
      # amtool, which ships with Alertmanager: the runbook silences alerts with it.
      environment.systemPackages = [ pkgs.prometheus-alertmanager ];

      homeserver.notify.units = [
        "alertmanager"
        "alert-relay"
      ];

      # Prometheus starts after Alertmanager: an alert it fails to deliver is
      # sent again only after its resend delay, a minute, so at boot an alert
      # firing before Alertmanager listened was missing for that long, and an
      # inhibition whose source alert was the one lost did not hold (found by
      # tests/alerting.nix, where DnsFailing posted despite a dead gateway).
      systemd.services.prometheus = {
        after = [ "alertmanager.service" ];
        wants = [ "alertmanager.service" ];
      };
      # Started means ready to take alerts, not merely launched (the unit is
      # Type=simple), or the ordering above would gain nothing. The wait is
      # bounded: an Alertmanager that is not ready within 100 seconds fails
      # its start (the time limit is a little longer, so the script's own
      # message is what the journal shows), and after five such starts in
      # 15 minutes the unit stays failed, which the notifier posts
      # (modules/base/notify.nix). Without the limit the module's
      # Restart=always would restart it for ever, never failing. 100 seconds,
      # not less: a loaded emulated test VM took 65 to get it ready.
      systemd.services.alertmanager = {
        postStart = ''
          deadline=$((SECONDS + 100))
          until ${lib.getExe pkgs.curl} -fsS -o /dev/null http://127.0.0.1:${toString ports.alertmanager}/-/ready; do
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "Alertmanager not ready after 100 s" >&2
              exit 1
            fi
            sleep 1
          done
        '';
        serviceConfig = {
          TimeoutStartSec = 120;
          RestartSec = 5;
        };
        unitConfig = {
          StartLimitIntervalSec = 900;
          StartLimitBurst = 5;
        };
      };

      services.prometheus.alertmanagers = [
        { static_configs = [ { targets = [ "127.0.0.1:${toString ports.alertmanager}" ]; } ]; }
      ];

      services.prometheus.alertmanager = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = ports.alertmanager;
        # An empty address turns the cluster listener off.
        extraFlags = [ "--cluster.listen-address=" ];
        # The module runs `amtool check-config` on this at build time.
        checkConfig = true;
        configuration = {
          route = {
            receiver = "discord";
            # Every alert is its own notification: the alerts are different
            # things, and the title is each one's summary.
            group_by = [ "..." ];
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "12h";
          };
          receivers = [
            {
              name = "discord";
              webhook_configs = [
                {
                  url = "http://127.0.0.1:${toString ports.relay}/";
                  send_resolved = true;
                  # Above the relay's own limit per post (alert-relay.py), and
                  # under group_interval, after which Alertmanager would
                  # retry anyway.
                  timeout = "4m";
                }
              ];
            }
          ];
          # A dead gateway also fails the DNS (Domain Name System) probe and drops the tailnet:
          # one message about the cause is enough. No `equal` labels: the
          # three alerts come from different jobs and share none.
          inhibit_rules = [
            {
              source_matchers = [ ''alertname="GatewayUnreachable"'' ];
              target_matchers = [ ''alertname=~"DnsFailing|TailnetDisconnected"'' ];
            }
          ];
        };
      };

      systemd.services.alert-relay = {
        description = "Relay Alertmanager's alerts to Discord";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        # Five tries in 5 minutes, then the unit stays failed, which the
        # notifier posts (modules/base/notify.nix). Without the limit a relay
        # that cannot start, such as one whose secret is missing, restarts
        # every 5 seconds for ever and never reaches `failed`.
        unitConfig = {
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };
        serviceConfig = {
          # %d is the credentials directory, expanded by systemd; the files
          # are readable by this unit alone, as for notify-failure@.
          ExecStart = lib.escapeShellArgs [
            (lib.getExe pkgs.python3)
            "-I"
            "${./alert-relay.py}"
            (lib.getExe notify.sender)
            "%d/webhook"
            roleArg
            host
            (toString ports.relay)
          ];
          DynamicUser = true;
          LoadCredential = [
            "webhook:${notify.webhookFile}"
          ]
          ++ lib.optional (notify.roleFile != null) "role:${notify.roleFile}";
          Restart = "on-failure";
          RestartSec = 5;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          ProtectHome = true;
          PrivateDevices = true;
        };
      };
    })
  ];
}
