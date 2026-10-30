# The LAN's (local area network's) DNS (Domain Name System) server, ticket
# #164 (docs/superpowers/specs/2026-10-29-lan-dns-design.md).
#
# Blocky answers the LAN on port 53 of the nuc's LAN address. It blocks names
# on the lists (./lists.nix), answers the local names declared here and the
# private ones from a file sops writes, and sends everything else to Unbound
# (./unbound.nix), which resolves from the root servers on 127.0.0.1. Names
# under home.arpa, and reverse lookups for the LAN, go to the router, which
# knows the DHCP (Dynamic Host Configuration Protocol) devices' names.
#
# The nuc's own lookups don't use any of this: its resolver is the router
# (hosts/nuc/network.nix), so its boot, comin, the alert relay and the list
# downloads never depend on Blocky.
{
  config,
  lib,
  ...
}:
let
  cfg = config.homeserver.dns;
  router = config.homeserver.network.router;
  enabled = cfg.listenAddresses != [ ];

  # Blocky takes a source with a line break in it as the list itself rather
  # than a URL or a path.
  inline = names: lib.concatMapStrings (name: "${name}\n") names;
  # Where systemd puts the credential below, readable by Blocky's dynamic
  # user alone. The YAML (YAML Ain't Markup Language) file can't use `%d`,
  # which only systemd expands, so the path is spelled out.
  privateHostsCredential = "/run/credentials/blocky.service/private-hosts";
in
{
  imports = [
    ./querylog.nix
    ./unbound.nix
  ];

  options.homeserver.dns = {
    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.1.131" ];
      description = ''
        Addresses Blocky answers DNS on, port 53. Empty means the DNS server
        is off. Never 127.0.0.53, which systemd-resolved holds.
      '';
    };

    lists = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = import ./lists.nix;
      description = ''
        Blocklists by group: URLs or local paths, in a format Blocky reads
        (hosts, one domain per line, `*.` wildcards). The group names are what
        the query log and the alerts show.
      '';
    };

    allow = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names never blocked, whichever list has them.";
    };

    deny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names blocked in addition to the lists, counted as ads.";
    };

    records = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        "grafana.home.arpa" = [ "192.168.1.131" ];
      };
      description = ''
        Local names and the IPv4 or IPv6 addresses they answer with. Each
        module declares its own service's name. Public: for a name that must
        stay private, use `privateHostsFile`.
      '';
    };

    privateHostsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path, at run time, of a hosts-format file of local names that must not
        be public, such as a sops secret. Passed to Blocky as a systemd
        credential; never read while the configuration is built, so its
        contents stay out of the Nix store.
      '';
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "Blocky's API (application programming interface) and metrics, on 127.0.0.1.";
    };

    unboundPort = lib.mkOption {
      type = lib.types.port;
      default = 5335;
      description = "Unbound's port, on 127.0.0.1.";
    };
  };

  config = lib.mkIf enabled {
    # Failures post to the alerts channel (modules/base/notify.nix).
    homeserver.notify.units = [
      "blocky"
      "unbound"
    ];

    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = map (address: "${address}:53") cfg.listenAddresses;
          http = "127.0.0.1:${toString cfg.httpPort}";
        };
        upstreams.groups.default = [ "127.0.0.1:${toString cfg.unboundPort}" ];
        # Blocky resolves names in its own configuration, the list URLs among
        # them, through the router, like the rest of the nuc.
        bootstrapDns = [ { upstream = router; } ];
        # The LAN's own names, and the names of its addresses, are the
        # router's.
        conditional.mapping = {
          "home.arpa" = router;
          "1.168.192.in-addr.arpa" = router;
        };
        # Device names for the query log, from the router's reverse names.
        clientLookup.upstream = router;
        customDNS.mapping = lib.mapAttrs (_: lib.concatStringsSep ",") cfg.records;
        hostsFile = lib.mkIf (cfg.privateHostsFile != null) {
          sources = [ privateHostsCredential ];
        };
        blocking = {
          denylists =
            cfg.lists
            // lib.optionalAttrs (cfg.deny != [ ]) { ads = (cfg.lists.ads or [ ]) ++ [ (inline cfg.deny) ]; };
          allowlists = lib.mkIf (cfg.allow != [ ]) (lib.mapAttrs (_: _: [ (inline cfg.allow) ]) cfg.lists);
          # Every device, every group: `ads` and `threats`.
          clientGroupsBlock.default = lib.attrNames cfg.lists;
          loading = {
            # Answer at once and block once the lists have loaded: at boot,
            # or with a list's server down, the house keeps resolving.
            strategy = "fast";
            refreshPeriod = "24h";
            # A list stops loading at its sixth line Blocky can't parse, and
            # DandelionSprout's has four (./lists.nix). Enough headroom that
            # a few more don't silently cut a list short.
            maxErrorsPerSource = 100;
          };
        };
        prometheus.enable = true;
      };
    };

    systemd.services.blocky = {
      # Blocky binds the LAN address, which exists only once DHCP has given
      # it, and asks Unbound. nixpkgs' module already wants
      # network-online.target, but doesn't wait for it.
      after = [
        "network-online.target"
        "unbound.service"
      ];
      serviceConfig = {
        # Blocky exits when it can't bind the address, as when the router
        # boots slower than the nuc after a power cut and lan0 has no address
        # yet. Keep retrying for as long as that takes: 5 seconds apart at
        # first, backing off to once a minute. Restart = "on-failure" is
        # nixpkgs' own. A Blocky that never comes up is reported by the DNS
        # probe's alert, not by a failed unit.
        RestartSec = 5;
        RestartSteps = 5;
        RestartMaxDelaySec = 60;
        LoadCredential = lib.mkIf (cfg.privateHostsFile != null) "private-hosts:${cfg.privateHostsFile}";
      };
      # No start limit: with one, a slow router left the unit failed for good
      # after five tries (tests/dns.py, "the LAN address arrives late").
      unitConfig.StartLimitIntervalSec = 0;
    };

    # Port 53 on the LAN port only, never on the tailnet. On lan0 rather than
    # on an address, so IPv6 needs no new rule when it is turned on.
    networking.firewall.interfaces.lan0 = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };
  };
}
