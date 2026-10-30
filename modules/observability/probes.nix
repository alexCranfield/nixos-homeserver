# The metrics #27's rules need that no exporter gives for free:
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
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.alerting;
  blackboxPort = 9115;
  textDir = "/var/lib/prometheus-node-exporter-text";

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
    };
  };

  # Prometheus scrapes the exporter, not the target: the target goes in as a
  # parameter and the exporter probes it.
  probe = job: module: target: {
    job_name = job;
    metrics_path = "/probe";
    params.module = [ module ];
    static_configs = [ { targets = [ target ]; } ];
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

  config = {
    assertions = [
      {
        assertion = (config.boot.kernel.sysctl."net.ipv4.ping_group_range" or null) == "0 2147483647";
        message = "homeserver.alerting: the ICMP probe needs unprivileged ping sockets, so net.ipv4.ping_group_range must be \"0 2147483647\" (NixOS's default); the exporter has no CAP_NET_RAW.";
      }
    ];

    homeserver.notify.units = [
      "tailscale-state"
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

    systemd.timers.tailscale-state = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "30s";
      };
    };
  };
}
