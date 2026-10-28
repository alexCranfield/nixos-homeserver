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
#  - itself.
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
# Everything listens on 127.0.0.1 only. Port 8080, cAdvisor's default, is the
# hello stack's, so cAdvisor takes 8081.
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
    cadvisor = 8081;
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
  options.homeserver.observability.grafanaAdminPasswordFile = lib.mkOption {
    type = lib.types.path;
    description = ''
      File holding the password of Grafana's `admin` user, readable by the
      `grafana` user. Read when Grafana first creates its database; see
      docs/runbooks/observability.md for changing it afterwards.
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
      };
      path = [
        config.services.grafana.package
        pkgs.curl
        pkgs.gnugrep
      ];
      script = ''
        # The server makes the database and the admin user on its first start.
        for _ in $(seq 60); do
          curl -fsS -o /dev/null http://127.0.0.1:${toString ports.grafana}/api/health && break
          sleep 2
        done
        out=$(grafana cli --homepath ${config.services.grafana.dataDir} --config ${grafanaIni} \
          admin reset-admin-password --password-from-stdin \
          < ${cfg.grafanaAdminPasswordFile} 2>&1)
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
        # tailscaled may not be ready to take Serve settings at once.
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = ports.grafana;
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
