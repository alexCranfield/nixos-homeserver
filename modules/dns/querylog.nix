# The DNS (Domain Name System) query log, ticket #164: Blocky writes every
# query to a local PostgreSQL database, Grafana reads it (the query log
# section of docs/superpowers/specs/2026-10-29-lan-dns-design.md).
#
# Everything goes over PostgreSQL's socket with peer authentication: the
# server maps the operating-system user on the other end to the role of the
# same name, so there is no password and no secret. Blocky's dynamic user is
# `blocky` while it runs, Grafana's user is `grafana`. PostgreSQL listens on
# no network address at all.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.dns;
  enabled = cfg.listenAddresses != [ ];
  psqlDatabase = "blocky";
  readers = [
    "grafana"
    "dns-watch"
  ];
  quote = name: ''"${name}"'';
  readerList = lib.concatMapStringsSep ", " quote readers;

  pgIsReady = "${config.services.postgresql.finalPackage}/bin/pg_isready -q -t 3 -h /run/postgresql -d ${psqlDatabase}";
in
{
  config = lib.mkIf enabled {
    services.postgresql = {
      enable = true;
      # The socket only: no network address to listen on.
      settings.listen_addresses = lib.mkForce "";
      ensureDatabases = [ psqlDatabase ];
      ensureUsers = [
        {
          # Owns the database, so Blocky can create and migrate its table.
          name = "blocky";
          ensureDBOwnership = true;
        }
        # Read-only roles, granted below. `dns-watch` is for the alert
        # queries, which run as an operating-system user of the same name;
        # that user is added with them, and only the role exists until then.
        { name = "grafana"; }
        { name = "dns-watch"; }
      ];
    };

    # Blocky creates the table when it first starts, so the readers' rights
    # can't be granted on it before then: default privileges give them
    # SELECT on whatever `blocky` creates in the schema. The second grant
    # covers a table that already exists, which makes this safe to run on
    # every start. Nothing else is granted: no INSERT, UPDATE, DELETE or
    # CREATE.
    systemd.services.dns-querylog-grants = {
      description = "Let Grafana read the DNS query log";
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql-setup.service" ];
      after = [ "postgresql-setup.service" ];
      before = [ "blocky.service" ];
      path = [ config.services.postgresql.finalPackage ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
      };
      script = ''
        psql --no-psqlrc -v ON_ERROR_STOP=1 -d ${psqlDatabase} <<'SQL'
        REVOKE CONNECT ON DATABASE ${psqlDatabase} FROM PUBLIC;
        GRANT CONNECT ON DATABASE ${psqlDatabase} TO ${readerList};
        GRANT USAGE ON SCHEMA public TO ${readerList};
        ALTER DEFAULT PRIVILEGES FOR ROLE blocky IN SCHEMA public
          GRANT SELECT ON TABLES TO ${readerList};
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${readerList};
        SQL
      '';
    };

    services.blocky.settings.queryLog = {
      type = "postgresql";
      target = "postgres://blocky@/${psqlDatabase}?host=/run/postgresql";
      # The household's browsing: no longer than the curiosity use needs.
      logRetentionDays = 14;
    };

    # Once running, Blocky keeps answering with PostgreSQL stopped; the
    # wants, not requires, keeps it from being stopped with PostgreSQL.
    systemd.services.blocky = {
      wants = [ "dns-querylog-grants.service" ];
      after = [ "dns-querylog-grants.service" ];
    };

    # Blocky 0.29 tries three times, 2 seconds apart, to open the log's
    # database at start, then carries on logging to its console instead (and
    # DNS keeps answering). It doesn't try again, so a start while PostgreSQL
    # is down loses the log until Blocky restarts. Every five minutes, if the
    # current Blocky run said it fell back and PostgreSQL is back, restart it
    # to log again. A restart is a second without an answer on port 53, so
    # only when needed.
    systemd.services.dns-querylog-reattach = {
      description = "Restart Blocky to log queries again, once PostgreSQL is back";
      serviceConfig.Type = "oneshot";
      path = [
        config.systemd.package
        pkgs.gnugrep
      ];
      script = ''
        id=$(systemctl show -P InvocationID blocky.service)
        if [ -n "$id" ] \
          && journalctl --no-pager _SYSTEMD_INVOCATION_ID="$id" | grep -qF 'using console as fallback' \
          && ${pgIsReady}; then
          echo "PostgreSQL is back: restarting Blocky to log queries again"
          systemctl restart blocky.service
        fi
      '';
    };
    systemd.timers.dns-querylog-reattach = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
      };
    };

    # The hard cap on the log's size (querylog-cap.sql explains the method).
    # It needs DELETE, which neither Grafana's nor dns-watch's role has, so it
    # is its own unit, run as the `postgres` operating-system user (peer
    # authentication, superuser) rather than giving a reader write rights.
    # Every 10 minutes: the gate is one size lookup, a flood that matters
    # takes hours to reach the cap (the alert DnsQueryLogLarge fires at
    # 2 GB, five times lower), and more often would only run the estimate,
    # which reads the table's newest rows, more.
    systemd.services.dns-querylog-cap = {
      description = "Keep the DNS query log under its size cap";
      after = [ "postgresql.service" ];
      path = [ config.services.postgresql.finalPackage ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        # Not forever (a hung job would stop the timer), but long enough for
        # a delete and vacuum of a multi-gigabyte table; under the 10-minute
        # period so a run never overlaps the next.
        TimeoutStartSec = "9min";
      };
      script = ''
        psql --no-psqlrc -q -d ${psqlDatabase} -v cap=${toString cfg.queryLogMaxBytes} -f ${./querylog-cap.sql}
      '';
    };
    systemd.timers.dns-querylog-cap = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "10min";
      };
    };
  };
}
