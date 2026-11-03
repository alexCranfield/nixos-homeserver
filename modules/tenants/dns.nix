# The tenant VMs' (virtual machines') DNS (Domain Name System) server, ticket
# 6.7 (#197); ADR (Architecture Decision Record) 0013, decision 2.
#
# The VMs don't ask the LAN's (local area network's) Blocky. Blocky answers
# its local records and private hosts file, reverse lookups included, before
# it applies any blocking, and forwards home.arpa and the LAN's reverse names
# to the router; a VM could walk 192.168.1.1 to .254 and read back the
# house's private device names. Per-client blocking can't stop that, since it
# comes later in Blocky's chain.
#
# So the VMs get a Blocky of their own, `blocky-tenant`, on 10.88.0.1: the
# LAN Blocky's settings, the same lists and the same Unbound, without the
# local records, the private hosts file, the forwarding to the router or the
# router's reverse names for clients. Unbound answers home.arpa and the
# private reverse zones itself, with nothing (its default local zones), so no
# LAN name gets out that way either.
#
# It runs as the same dynamic user, `blocky`, which systemd shares between
# units, so it writes to the same query log with the same database role: the
# dashboard and the DNS alerts see the VMs, named `tenant-dev` and
# `tenant-run`, with no change of their own.
#
# 10.88.0.1 is the host's address on every tap, but a tap exists only while
# its VM runs. A dummy interface, `tenant-dns`, holds the address always, so
# Blocky can bind it at boot. Nothing is routed through the dummy.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.tenants;
  enabled = cfg.vms != { } && config.homeserver.dns.listenAddresses != [ ];
  httpPort = 4001;

  settings =
    lib.removeAttrs config.services.blocky.settings [
      "customDNS"
      "hostsFile"
      "conditional"
      "clientLookup"
    ]
    // {
      ports = {
        dns = [ "${cfg.hostAddress}:53" ];
        http = "127.0.0.1:${toString httpPort}";
      };
      clientLookup.clients = lib.mapAttrs (_: vm: [ "${cfg.subnet}.${toString vm.index}" ]) cfg.vms;
    };
  configFile = (pkgs.formats.yaml { }).generate "blocky-tenant.yml" settings;

  lan = config.systemd.services.blocky;

  # Both Blockys create the query log's table when they start, and two at
  # once collide in PostgreSQL's catalog ("duplicate key value violates
  # unique constraint pg_type_typname_nsp_index"); Blocky retries three
  # times and then logs to its console instead. So this one starts after the
  # LAN's has made the table, up to a minute, and then starts regardless:
  # the tenants' DNS doesn't wait on the log.
  waitForTable = pkgs.writeShellScript "blocky-tenant-wait-for-log" ''
    for _ in $(${pkgs.coreutils}/bin/seq 60); do
      if ${config.services.postgresql.finalPackage}/bin/psql -h /run/postgresql -d blocky -Atc \
        "SELECT 1 FROM information_schema.columns WHERE table_name = 'log_entries' AND column_name = 'id'" \
        2> /dev/null | ${pkgs.gnugrep}/bin/grep -qx 1; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "the query log's table is still missing; starting anyway" >&2
  '';
in
{
  config = lib.mkIf enabled {
    systemd.network.netdevs."30-tenant-dns".netdevConfig = {
      Kind = "dummy";
      Name = "tenant-dns";
    };
    systemd.network.networks."30-tenant-dns" = {
      matchConfig.Name = "tenant-dns";
      address = [ "${cfg.hostAddress}/32" ];
      networkConfig.LinkLocalAddressing = "no";
      linkConfig.RequiredForOnline = "no";
    };

    systemd.services.blocky-tenant = {
      description = "DNS server for the tenant VMs";
      wantedBy = [ "multi-user.target" ];
      inherit (lan) wants;
      after = lan.after ++ [ "blocky.service" ];
      # The LAN Blocky's hardening and restart settings, with this
      # configuration and no private hosts file.
      serviceConfig =
        lib.removeAttrs lan.serviceConfig [
          "ExecStart"
          "LoadCredential"
          "LogsDirectory"
          # Shared, systemd would remove it under the other Blocky whenever
          # this one stops.
          "RuntimeDirectory"
        ]
        // {
          ExecStartPre = waitForTable;
          ExecStart = "${lib.getExe config.services.blocky.package} --config ${configFile}";
          User = "blocky";
          LogsDirectory = "blocky-tenant";
        };
      unitConfig.StartLimitIntervalSec = 0;
    };

    homeserver.notify.units = [ "blocky-tenant" ];
    homeserver.dns.queryLogUnits = [ "blocky-tenant" ];
  };
}
