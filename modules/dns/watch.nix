# Suspicious-activity metrics from the DNS (Domain Name System) query log,
# ticket #164 (the "Suspicious-activity alerts" section of
# docs/superpowers/specs/2026-10-29-lan-dns-design.md). Every minute a
# oneshot asks PostgreSQL (./watch.sql) about the last minutes of the log and
# writes the answers as a Prometheus text file, which node-exporter's textfile
# collector serves; the alert rules are in modules/observability/rules.nix.
#
# The queries run as the dynamic user `dns-watch`, which peer authentication
# (./querylog.nix) maps to the role of that name: it can connect and SELECT
# from the log, and nothing else.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.dns;
  enabled = cfg.listenAddresses != [ ];
  # Where node-exporter reads (modules/observability/probes.nix).
  textDir = "/var/lib/prometheus-node-exporter-text";
  psqlDatabase = "blocky";

  # Runs as root (the `+` in ExecStartPost below). The directory is root's, so
  # the dynamic user can't write there; its unit writes into its own
  # RuntimeDirectory instead, and this copies the file across. Chosen over a
  # group-writable file because it needs no shared group and no permissions
  # beyond the unit's own sandbox. The copy goes to a name beside the target
  # and is renamed, so node-exporter never reads half a file; the name does
  # not end in `.prom`, which it would read.
  publish = pkgs.writeShellScript "dns-watch-publish" ''
    set -eu
    tmp=$(${pkgs.coreutils}/bin/mktemp ${textDir}/.dns-watch.XXXXXX)
    ${pkgs.coreutils}/bin/cat /run/dns-watch/dns-watch.prom > "$tmp"
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" ${textDir}/dns-watch.prom
  '';
in
{
  config = lib.mkIf enabled {
    systemd.services.dns-watch = {
      description = "Write the DNS query log's suspicious-activity metrics for node-exporter";
      # After the setup that creates the database and its roles, not only
      # the server, as dns-querylog-cap (querylog.nix).
      requires = [ "postgresql-setup.service" ];
      after = [ "postgresql-setup.service" ];
      path = [ config.services.postgresql.finalPackage ];
      serviceConfig = {
        Type = "oneshot";
        # A hung psql would block the oneshot, and the timer would never
        # fire again, leaving the old file: kill it well inside the minute
        # (DnsWatchFailing also fires on a file gone stale).
        TimeoutStartSec = "50s";
        DynamicUser = true;
        User = "dns-watch";
        # /run/dns-watch, owned by the dynamic user.
        RuntimeDirectory = "dns-watch";
        ExecStartPost = "+${publish}";
        # Only PostgreSQL's socket.
        RestrictAddressFamilies = "AF_UNIX";
      };
      # A failing query is a result, not an error of this unit: it writes
      # `homeserver_dns_watch_success 0` and exits 0, and the alert
      # DnsWatchFailing speaks for it after ten minutes. The unit fails only
      # if the file cannot be written.
      script = ''
        out=/run/dns-watch/dns-watch.prom
        # Each statement ends by itself too, before the unit's timeout.
        export PGOPTIONS='-c statement_timeout=40s'
        if rows=$(psql --no-psqlrc -q -At -v ON_ERROR_STOP=1 -h /run/postgresql -d ${psqlDatabase} -f ${./watch.sql}); then
          success=1
        else
          rows=""
          success=0
        fi
        {
          if [ -n "$rows" ]; then printf '%s\n' "$rows"; fi
          echo '# HELP homeserver_dns_watch_success 1 if the watch queries of the DNS query log ran.'
          echo '# TYPE homeserver_dns_watch_success gauge'
          echo "homeserver_dns_watch_success $success"
        } > "$out"
      '';
    };

    systemd.timers.dns-watch = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
