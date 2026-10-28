# Metrics for the nuc and its containers, ticket 3.4 (#25,
# docs/runbooks/observability.md).
#
# Prometheus scrapes, every 15 seconds:
#
#  - node-exporter: the host (CPU, memory, disk, network, temperatures) and,
#    with its systemd collector, each unit's state, which #27's failed-unit
#    rule reads;
#  - cAdvisor: each container's CPU, memory and network;
#  - comin's own exporter (modules/base/comin.nix): fetch, evaluation, build
#    and deployment results, which #27's rules read;
#  - itself;
#  - the blackbox exporter, which probes the LAN gateway and the system's DNS,
#    and node-exporter's textfile collector, which carries Tailscale's state
#    (probes.nix).
#
# All of them are native services, not containers: ADR (Architecture Decision
# Record) 0006 gives no container the Docker socket, and the metrics keep
# coming when Docker is what's broken. cAdvisor reads Docker's state as root,
# which a native service may.
#
# Grafana draws them, also native: its dashboards then outlive a Docker
# failure too, and its settings come from Nix and sops (ADR 0006's note of
# 2026-10-27). Its data source and dashboards are provisioned from the repo
# and can't be changed in its UI (user interface), so a reinstall brings them
# back as they were.
#
# Everything listens on 127.0.0.1 only. cAdvisor's default, 8080, is the hello
# stack's, and 8081 a container port the VM tests publish (found by CI), so
# cAdvisor takes 9338, which nothing here uses.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.observability;
  ports = {
    prometheus = 9090;
    node = 9100;
    cadvisor = 9338;
    # Fixed by comin; its address is set in modules/base/comin.nix.
    comin = 4243;
    grafana = 3000;
  };
  scrape = job: port: {
    job_name = job;
    static_configs = [ { targets = [ "127.0.0.1:${toString port}" ]; } ];
  };

  # grafana.com dashboards, pinned by revision and hash rather than copied
  # into the repo: their licences are their authors', and a revision never
  # changes once published.
  grafanaCom =
    id: revision: hash:
    pkgs.fetchurl {
      name = "grafana-dashboard-${toString id}-${toString revision}.json";
      url = "https://grafana.com/api/dashboards/${toString id}/revisions/${toString revision}/download";
      inherit hash;
    };
  dashboards = pkgs.runCommand "nuc-dashboards" { } ''
    mkdir $out
    # Node Exporter Full: the host.
    cp ${grafanaCom 1860 45 "sha256-GExrdAnzBtp1Ul13cvcZRbEM6iOtFrXXjEaY6g6lGYY="} $out/host.json
    # cAdvisor dashboard: containers, by Compose project and name. Exports
    # from grafana.com name their data source `''${DS_PROMETHEUS}`, filled in
    # by Grafana's import dialog; provisioning has no dialog, so it is filled
    # in here.
    sed 's/''${DS_PROMETHEUS}/prometheus/g' \
      ${grafanaCom 19792 6 "sha256-ljSNfGjm0pztO6mo2kNYuGBb5oFb5S2vbYvoWkT5SXE="} \
      > $out/containers.json
    cp ${./dashboards/game-servers.json} $out/game-servers.json
  '';
  secretKey = "/var/lib/grafana/secret_key";

  # The same rendering as nixpkgs' Grafana module (its `settingsFormatIni`),
  # so `grafana cli` reads the configuration the server runs with and opens
  # the same database. The module keeps its own file private.
  grafanaIni =
    (pkgs.formats.ini {
      listToValue = lib.concatMapStringsSep " " (lib.generators.mkValueStringDefault { });
      mkKeyValue = lib.generators.mkKeyValueDefault {
        mkValueString = v: if v == null then "" else lib.generators.mkValueStringDefault { } v;
      } "=";
    }).generate
      "grafana-cli.ini"
      config.services.grafana.settings;
in
{
  imports = [
    ./alerting.nix
    ./probes.nix
  ];

  options.homeserver.observability.grafanaAdminPasswordFile = lib.mkOption {
    type = lib.types.path;
    description = ''
      File holding the password of Grafana's `admin` user, readable by the
      `grafana` user. Grafana reads it when it first creates its database,
      and `grafana-admin-password.service` sets it again after every start,
      so the file stays the password (docs/runbooks/observability.md).
    '';
  };

  config = {
    # Failures post to the alerts channel (modules/base/notify.nix).
    homeserver.notify.units = [
      "prometheus"
      "prometheus-node-exporter"
      "cadvisor"
      "grafana"
      "grafana-admin-password"
      "tailscale-serve-grafana"
    ];

    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.prometheus;
      globalConfig.scrape_interval = "15s";
      # Whichever limit comes first. At this scale a month is expected to take
      # 1 to 2 GB; the size cap is there in case a new exporter is far chattier.
      retentionTime = "30d";
      extraFlags = [ "--storage.tsdb.retention.size=10GB" ];
      scrapeConfigs = [
        (scrape "node" ports.node)
        (scrape "cadvisor" ports.cadvisor)
        (scrape "comin" ports.comin)
        (scrape "prometheus" ports.prometheus)
      ];
    };

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.node;
      # On top of the default collectors.
      enabledCollectors = [ "systemd" ];
    };

    services.cadvisor = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.cadvisor;
      # Docker 29 keeps images in containerd's snapshotter, and cAdvisor then
      # reads Docker's containers through containerd (namespace `moby`), at
      # the address this flag sets. Docker runs its own containerd, not the
      # system one at the default /run/containerd/containerd.sock; without the
      # flag cAdvisor drops Docker altogether and reports containers only as
      # unnamed cgroups (found by tests/observability.nix).
      extraOptions = [ "--containerd=/run/docker/containerd/containerd.sock" ];
    };

    # cAdvisor looks for Docker once, when it starts, and does without it if
    # Docker isn't there yet. So it starts after Docker, and restarts with it.
    systemd.services.cadvisor = {
      wants = [ "docker.service" ];
      after = [ "docker.service" ];
      partOf = [ "docker.service" ];
    };
    # Grafana encrypts secrets it stores in its database with this key, and
    # refuses to start without one. This setup stores none (the Prometheus
    # source needs no credentials), so the key is made on the host the first
    # time and never leaves it; a reinstall makes a new one and loses nothing.
    systemd.services.grafana-secret-key = {
      description = "Make Grafana's secret key, once";
      before = [ "grafana.service" ];
      requiredBy = [ "grafana.service" ];
      unitConfig.ConditionPathExists = "!${secretKey}";
      serviceConfig = {
        Type = "oneshot";
        User = "grafana";
        UMask = "0077";
      };
      script = ''
        # Left behind, read-only, if a run died before the rename.
        rm -f ${secretKey}.tmp
        head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 > ${secretKey}.tmp
        chmod 0400 ${secretKey}.tmp
        mv ${secretKey}.tmp ${secretKey}
      '';
    };

    # Grafana reads `admin_password` only when it first creates its database.
    # So that the sops secret stays the password after that too, this sets it
    # again each time Grafana starts, and whenever the secret changes
    # (hosts/nuc/observability.nix restarts it). `grafana cli` exits 0 even
    # when it finds no admin user to change, so success is read from what it
    # prints.
    #
    # The password is read as Grafana's own file provider reads it, trimmed
    # of spaces and newlines at both ends, so the first start and the later
    # ones agree; a secret of more than one line is refused rather than cut
    # to its first line, as the CLI's stdin would. A Grafana that isn't
    # healthy fails the unit rather than leaving the CLI on a database the
    # server may still be making, and the time limit keeps a stuck CLI from
    # holding up a deploy.
    systemd.services.grafana-admin-password = {
      description = "Set Grafana's admin password from its secret";
      after = [ "grafana.service" ];
      partOf = [ "grafana.service" ];
      wantedBy = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "grafana";
        WorkingDirectory = config.services.grafana.dataDir;
        TimeoutStartSec = 330;
      };
      path = [
        config.services.grafana.package
        pkgs.curl
        pkgs.gnugrep
      ];
      script = ''
        password=$(< ${cfg.grafanaAdminPasswordFile})
        password=''${password#"''${password%%[![:space:]]*}"}
        password=''${password%"''${password##*[![:space:]]}"}
        if [[ -z $password || $password == *$'\n'* ]]; then
          echo "the password file must hold one non-empty line" >&2
          exit 1
        fi

        # The server makes the database and the admin user on its first start,
        # which can take minutes (its migrations); later starts take seconds.
        healthy=
        for _ in $(seq 150); do
          if curl -fsS -o /dev/null http://127.0.0.1:${toString ports.grafana}/api/health; then
            healthy=1
            break
          fi
          sleep 2
        done
        if [[ -z $healthy ]]; then
          echo "Grafana not healthy after 300 s; password not set" >&2
          exit 1
        fi

        out=$(printf '%s\n' "$password" \
          | grafana cli --homepath ${config.services.grafana.dataDir} --config ${grafanaIni} \
            admin reset-admin-password --password-from-stdin 2>&1)
        if ! grep -q "Admin password changed successfully" <<< "$out"; then
          printf '%s\n' "$out" >&2
          exit 1
        fi
      '';
    };

    # Grafana on the tailnet: Tailscale Serve proxies the nuc's tailnet
    # address, port 3000, to Grafana on loopback, over plain HTTP. HTTPS would
    # need a certificate for the tailnet's name, and every public certificate
    # is published in the Certificate Transparency logs; WireGuard already
    # encrypts the traffic (#163 is HTTPS on a name of our own). Serve answers
    # inside tailscaled, so the firewall never sees it, but the tailnet's
    # access policy does limit it (docs/runbooks/tailscale.md).
    #
    # Not nixpkgs' `services.tailscale.serve`: that configures Tailscale
    # Services (`svc:` names approved in the admin console), not this
    # machine's own Serve. Serve's configuration persists in tailscaled's
    # state, so stopping the unit, as removing it from the configuration
    # does, takes the port back.
    systemd.services.tailscale-serve-grafana = {
      description = "Publish Grafana on the tailnet with Tailscale Serve";
      # Runs once the nuc is logged in; the VM tests start autoconnect late,
      # and this follows it.
      wantedBy = [ "tailscaled-autoconnect.service" ];
      after = [
        "tailscaled-autoconnect.service"
        "grafana.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe config.services.tailscale.package} serve --bg --http=${toString ports.grafana} http://127.0.0.1:${toString ports.grafana}";
        ExecStop = "${lib.getExe config.services.tailscale.package} serve --http=${toString ports.grafana} off";
        # tailscaled may not be ready to take Serve settings at once. Five
        # tries, then the unit fails and so posts (modules/base/notify.nix);
        # without the limit it would retry for ever, never failing. The time
        # limit keeps a stuck `tailscale serve` from holding up a deploy.
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = 60;
      };
      unitConfig = {
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = ports.grafana;
          # How Grafana names itself in links it makes (alerts from #27,
          # shared links); the default would say localhost.
          root_url = "http://nuc:${toString ports.grafana}/";
        };
        security = {
          admin_user = "admin";
          admin_password = "$__file{${cfg.grafanaAdminPasswordFile}}";
          secret_key = "$__file{${secretKey}}";
          disable_gravatar = true;
          # Plain HTTP over the tailnet (Tailscale Serve, below); a secure
          # cookie would never be sent back.
          cookie_secure = false;
        };
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
        # Nothing phones home.
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          check_for_plugin_updates = false;
          feedback_links_enabled = false;
        };
        news.news_feed_enabled = false;
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              url = "http://127.0.0.1:${toString ports.prometheus}";
              isDefault = true;
              editable = false;
            }
            # Shows what is firing and silenced (the alert rules, #27); the
            # alerts themselves are posted by Alertmanager, not Grafana.
            {
              name = "Alertmanager";
              type = "alertmanager";
              uid = "alertmanager";
              url = "http://127.0.0.1:9093";
              editable = false;
              jsonData = {
                implementation = "prometheus";
                handleGrafanaManagedAlerts = false;
              };
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "nuc";
              folder = "nuc";
              options.path = dashboards;
              allowUiUpdates = false;
              disableDeletion = true;
            }
          ];
        };
      };
    };
  };
}
