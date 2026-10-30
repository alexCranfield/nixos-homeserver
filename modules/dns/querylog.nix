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

    # Blocky exits when it can't open the log's database at start (as it
    # does for a missing LAN address), and the restarts in ./default.nix keep
    # trying. Once running, it keeps answering with PostgreSQL stopped; the
    # wants, not requires, keeps it from being stopped with PostgreSQL.
    systemd.services.blocky = {
      wants = [ "dns-querylog-grants.service" ];
      after = [ "dns-querylog-grants.service" ];
    };
  };
}
