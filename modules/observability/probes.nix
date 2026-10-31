# The metrics #27's rules need that no exporter gives for free, and the
# Minecraft player count (#168):
#
#  - Tailscale's state, which tailscaled does not export in a form the rules
#    can use. A timer runs `tailscale status --json` every 30 seconds and
#    writes the result to node-exporter's textfile collector (a directory of
#    `.prom` files it serves with its own metrics). Chosen over scraping
#    tailscaled's own metrics, which need the peer API's address; the text
#    file is simpler to test.
#  - The blackbox exporter, which Prometheus asks to probe two things: the
#    LAN (local area network) gateway with ICMP (Internet Control Message
#    Protocol) echo, and the system resolver with a DNS (Domain Name System)
#    lookup. The exporter runs without capabilities (the nixpkgs exporters
#    drop them all, including CAP_NET_RAW), so ICMP goes through unprivileged
#    ICMP datagram sockets, which the kernel allows for the groups in
#    `net.ipv4.ping_group_range`; an assertion below keeps that setting.
#  - The LAN's two DNS servers, the nuc's Blocky and the NAS's Pi-hole, each
#    probed from the nuc for two things: that it resolves a public name, and
#    that it blocks a name on the blocklists (every answer 0.0.0.0). The
#    label `server` (`nuc` or `nas`) names the server in the alerts. The
#    NAS's address is private, so it is not in this repository: it comes from
#    a file on the host that Prometheus reads at runtime (`file_sd`, file-based
#    service discovery). With no such file the NAS jobs have no targets.
#  - The Minecraft server's player count, whether it answers and how fast. A
#    timer runs `mc-monitor status` (from itzg, who makes the server's image)
#    against the port the container publishes on the host, and writes
#    textfile metrics as for Tailscale. It is not mc-monitor's own
#    `export-for-prometheus`, nor a container beside the server: the exporter
#    cannot bind to loopback only (it listens on every address), and a
#    container in `stacks/minecraft` changes that stack's files, which makes
#    comin's deploy recreate the stack's containers and kick the players.
#    This is a host unit, so a deploy leaves the server alone. It exports the
#    count and, from the ping's player sample, who is on (at most 12 names).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.alerting;
  dnsCfg = config.homeserver.dns;
  blackboxPort = 9115;
  textDir = "/var/lib/prometheus-node-exporter-text";
  # The port the Minecraft stack publishes on the host (stacks/minecraft).
  minecraftPort = 25565;
  mcMonitor = pkgs.callPackage ./mc-monitor.nix { };

  blackboxConfig = (pkgs.formats.yaml { }).generate "blackbox.yml" {
    modules = {
      icmp = {
        prober = "icmp";
        timeout = "5s";
        icmp.preferred_ip_protocol = "ip4";
      };
      # Asks the target, which is a DNS server, for the address of a public
      # name. A valid answer is what counts, whatever the address is.
      dns_local = {
        prober = "dns";
        timeout = "5s";
        dns = {
          query_name = "example.com";
          query_type = "A";
          preferred_ip_protocol = "ip4";
        };
      };
      # A public name, to a DNS server: any valid answer passes.
      dns_resolve = {
        prober = "dns";
        timeout = "5s";
        dns = {
          query_name = "example.com";
          query_type = "A";
          preferred_ip_protocol = "ip4";
        };
      };
      # A name on the blocklists. It passes only if the answer has records and
      # every one is 0.0.0.0, which is how Blocky and Pi-hole block. The
      # exporter fails `fail_if_not_matches_regexp` when any record does not
      # match, and also when there are none, so NXDOMAIN or an empty answer
      # (a server that is not answering sensibly) is not "blocked".
      dns_blocked = {
        prober = "dns";
        timeout = "5s";
        dns = {
          query_name = cfg.blockedProbeName;
          query_type = "A";
          preferred_ip_protocol = "ip4";
          validate_answer_rrs.fail_if_not_matches_regexp = [ "\\s0\\.0\\.0\\.0$" ];
        };
      };
    };
  };

  # The nuc is a static target; the NAS comes from the runtime file.
  dnsTargets =
    job: module:
    probeWith job module (
      lib.optionalAttrs (dnsCfg.listenAddresses != [ ]) {
        static_configs = [
          {
            targets = [ (builtins.head dnsCfg.listenAddresses) ];
            labels.server = "nuc";
          }
        ];
      }
      // lib.optionalAttrs (cfg.dnsServers.secondaryTargetsFile != null) {
        file_sd_configs = [ { files = [ cfg.dnsServers.secondaryTargetsFile ]; } ];
      }
    );

  # Prometheus scrapes the exporter, not the target: the target goes in as a
  # parameter and the exporter probes it. `sd` is the job's service
  # discovery: static targets, a `file_sd` file, or both.
  probeWith =
    job: module: sd:
    {
      job_name = job;
      metrics_path = "/probe";
      params.module = [ module ];
    }
    // sd
    // {
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "instance";
        }
        {
          target_label = "__address__";
          replacement = "127.0.0.1:${toString blackboxPort}";
        }
      ];
    };

  probe =
    job: module: target:
    probeWith job module { static_configs = [ { targets = [ target ]; } ]; };
in
{
  options.homeserver.alerting.gateway = lib.mkOption {
    type = lib.types.str;
    default = config.homeserver.network.router;
    description = ''
      The LAN's default gateway, the router, which the blackbox exporter pings.
      `GatewayUnreachable` fires when it stops answering.
    '';
  };

  options.homeserver.alerting.blockedProbeName = lib.mkOption {
    type = lib.types.str;
    default = "doubleclick.net";
    description = ''
      The name `DnsServerNotBlocking` asks both DNS servers for. It must be on
      the blocklists of both: it is on StevenBlack's list and on the NAS's.
    '';
  };

  options.homeserver.alerting.dnsServers.secondaryTargetsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Runtime path of a Prometheus `file_sd` JSON file naming the NAS's DNS
      server, `[{"targets": ["<address>"], "labels": {"server": "nas"}}]`. The
      address is private, so a sops template on the host writes the file and
      it never enters the repository. The file must be readable by the
      prometheus user. With `null`, the NAS has no probe jobs.
    '';
  };

  config = {
    assertions = [
      {
        assertion = (config.boot.kernel.sysctl."net.ipv4.ping_group_range" or null) == "0 2147483647";
        message = "homeserver.alerting: the ICMP probe needs unprivileged ping sockets, so net.ipv4.ping_group_range must be \"0 2147483647\" (NixOS's default); the exporter has no CAP_NET_RAW.";
      }
    ];

    homeserver.notify.units = [
      "tailscale-state"
      "minecraft-status"
      "prometheus-blackbox-exporter"
    ];

    services.prometheus.exporters.node = {
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textDir}" ];
    };

    # Written by tailscale-state as root, read by node-exporter's user.
    systemd.tmpfiles.rules = [ "d ${textDir} 0755 root root -" ];

    services.prometheus.exporters.blackbox = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = blackboxPort;
      configFile = blackboxConfig;
    };

    services.prometheus.scrapeConfigs = [
      (probe "blackbox_gateway" "icmp" cfg.gateway)
      # systemd-resolved's stub, which is where the system's DNS goes
      # (the router behind it, which forwards).
      (probe "blackbox_dns" "dns_local" "127.0.0.53")
      (dnsTargets "dns_resolve" "dns_resolve")
      (dnsTargets "dns_blocked" "dns_blocked")
    ];

    systemd.services.tailscale-state = {
      description = "Write Tailscale's state for node-exporter";
      # A failure of `tailscale status` is a result (not running), not an
      # error of this unit, so the script exits 0 in that case. The unit
      # fails only if the file cannot be written.
      serviceConfig.Type = "oneshot";
      path = [
        config.services.tailscale.package
        pkgs.jq
        pkgs.coreutils
      ];
      script = ''
        running=0
        health=0
        if out=$(timeout 20 tailscale status --json 2>/dev/null) \
          && r=$(jq -r 'if .BackendState == "Running" then 1 else 0 end' <<< "$out") \
          && h=$(jq -r '(.Health // []) | length' <<< "$out"); then
          running=$r
          health=$h
        fi

        # Written beside the target and renamed, so node-exporter never reads
        # half a file. Its name does not end in `.prom`, which it would read.
        tmp=$(mktemp ${textDir}/.tailscale.XXXXXX)
        cat > "$tmp" <<PROM
        # HELP homeserver_tailscale_running 1 if Tailscale's backend state is Running.
        # TYPE homeserver_tailscale_running gauge
        homeserver_tailscale_running $running
        # HELP homeserver_tailscale_health_messages Tailscale's current health warnings.
        # TYPE homeserver_tailscale_health_messages gauge
        homeserver_tailscale_health_messages $health
        PROM
        chmod 0644 "$tmp"
        mv "$tmp" ${textDir}/tailscale.prom
      '';
    };

    # A server that does not answer is a result (up 0, no count or timing),
    # not an error of this unit; it fails only if the file cannot be written.
    # A server that answers but is still loading reports no players and fails
    # mc-monitor's readiness check, so it counts as not answering.
    systemd.services.minecraft-status = {
      description = "Write the Minecraft server's player count for node-exporter";
      serviceConfig.Type = "oneshot";
      path = [
        mcMonitor
        pkgs.coreutils
        pkgs.jq
      ];
      script = ''
        up=0
        players=
        seconds=
        start=$(date +%s%N)
        if players=$(timeout 12 mc-monitor status --host 127.0.0.1 --port ${toString minecraftPort} \
          --timeout 10s --show-player-count 2>/dev/null) \
          && [[ $players =~ ^[0-9]+$ ]]; then
          up=1
          ns=$(( $(date +%s%N) - start ))
          seconds=$(printf '%d.%09d' $((ns / 1000000000)) $((ns % 1000000000)))
        fi

        # Who is on, from the status ping's player sample (`players.sample`,
        # which mc-monitor's JSON prints as `Sample`). The server decides what
        # is in it: vanilla lists at most 12 names, and a pack can hide it, so
        # this can be shorter than the count or empty. A second, best-effort
        # ping with a short timeout, so the count above never depends on it,
        # and a hung one cannot hold up the file for long. At most 12 names.
        # Only names that are valid Minecraft names (1 to 16 of A-Z, a-z, 0-9
        # and _) are kept, so nothing else reaches a label; `\` and `"` are escaped as well, which
        # a valid name never needs. \A and \z are the ends of the string,
        # where ^ and $ would also match at a newline inside it.
        names=
        if [[ $up == 1 ]]; then
          names=$(timeout 3 mc-monitor status --json --host 127.0.0.1 --port ${toString minecraftPort} \
            --timeout 2s 2>/dev/null \
            | jq -r '(.server_info.players.Sample // .server_info.players.sample // [])
                | map(.name? | select(type == "string" and test("\\A[A-Za-z0-9_]{1,16}\\z")))
                | unique | .[:12] | .[] | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")' 2>/dev/null) || names=
        fi

        # As tailscale-state: renamed into place, so never half a file.
        tmp=$(mktemp ${textDir}/.minecraft.XXXXXX)
        {
          echo "# HELP homeserver_minecraft_up 1 if the Minecraft server answered a status ping and is ready."
          echo "# TYPE homeserver_minecraft_up gauge"
          echo "homeserver_minecraft_up $up"
          if [[ $up == 1 ]]; then
            echo "# HELP homeserver_minecraft_players_online Players on the server, from the status ping's count."
            echo "# TYPE homeserver_minecraft_players_online gauge"
            echo "homeserver_minecraft_players_online $players"
            echo "# HELP homeserver_minecraft_response_seconds Time for the status ping, including starting mc-monitor."
            echo "# TYPE homeserver_minecraft_response_seconds gauge"
            echo "homeserver_minecraft_response_seconds $seconds"
            if [[ -n $names ]]; then
              echo "# HELP homeserver_minecraft_player_online 1 for each player named in the status ping's sample; the sample can be shorter than the count."
              echo "# TYPE homeserver_minecraft_player_online gauge"
              while IFS= read -r name; do
                echo "homeserver_minecraft_player_online{player=\"$name\"} 1"
              done <<< "$names"
            fi
          fi
        } > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" ${textDir}/minecraft.prom
      '';
    };

    systemd.timers.minecraft-status = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "15s";
      };
    };

    systemd.timers.tailscale-state = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "30s";
      };
    };
  };
}
