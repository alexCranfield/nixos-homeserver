# Prometheus alert rules for ticket #27, built from one attribute set of
# thresholds and durations so that tuning them never means editing a query.
#
# This file is a plain Nix function, not a NixOS module. It exports an
# attribute set with two members:
#
#   defaults  The starting thresholds, keyed by alert name. Each value is
#             `{ for = "10m"; }` plus, for the alerts that have a number to
#             tune, `value`. TemperatureHigh also has `fallback`, the limit in
#             degrees Celsius for a sensor that reports no `crit` mark.
#             DnsNxdomainBurst also has `factor`, how many times its baseline
#             a client's rate must exceed.
#             `homeserver.alerting.thresholds` defaults to this.
#   mkRules   `{ lib, thresholds, watchedUnits }: { groups = [ ... ]; }`.
#             `thresholds` is merged over `defaults`, so a caller may give only
#             the alerts it changes. `watchedUnits` lists unit names without
#             `.service` (`homeserver.notify.units`): their failures are
#             posted by the notifier already, so UnitFailed skips them.
#             The result is rendered to YAML by the caller.
#
# Every alert carries the label `severity` (`event` or `threshold`) and the
# annotations `summary`, which holds the value and the threshold, and
# `description`.
let
  defaults = {
    # Event alerts: a `for` and nothing to tune.
    TargetDown.for = "1m";
    UnitFailed.for = "0s";
    CominFetchFailed.for = "30m"; # a network blip
    CominEvalFailed.for = "0s";
    CominBuildFailed.for = "5m"; # comin reports a cancelled build as failed
    TailnetDisconnected.for = "2m";
    GatewayUnreachable.for = "2m";
    DnsFailing.for = "2m";
    DnsServerDown.for = "2m";
    # Longer than a list load: at boot Blocky resolves before its lists have
    # loaded (it fails open), and that must not alert.
    DnsServerNotBlocking.for = "15m";
    # The watch's series (modules/dns/watch.nix). A threat lookup or a new
    # device is worth knowing at once.
    DnsThreatBlocked.for = "0s";
    DnsNewClient.for = "0s";
    # The timer runs every minute; ten missed minutes is a real fault.
    DnsWatchFailing.for = "10m";
    OomKill.for = "0s";

    # Threshold alerts: long durations, to ignore normal busy spells.
    DiskFilling = {
      value = 85; # percent used
      for = "10m";
    };
    HostMemoryLow = {
      value = 10; # percent available
      for = "15m";
    };
    HostCpuHigh = {
      value = 90; # percent busy across all cores
      for = "15m";
    };
    TemperatureHigh = {
      value = 5; # degrees below the sensor's own `crit` mark
      fallback = 85; # degrees, for a sensor with no `crit` mark
      for = "5m";
    };
    ContainerCpuHigh = {
      value = 75; # percent of the whole host's CPU
      for = "15m";
    };
    StackMemoryNearLimit = {
      value = 90; # percent of the slice's own memoryMax
      for = "15m";
    };
    StackMemoryStalled = {
      value = 10; # percent of the time stalled
      for = "10m";
    };
    StackCpuStarved = {
      value = 25; # percent of the time waiting
      for = "15m";
    };
    DnsNxdomainBurst = {
      value = 10; # NXDOMAIN answers per minute, for one client
      factor = 5; # and this many times that client's own baseline
      for = "5m";
    };
    DnsQueryLogLarge = {
      value = 2000000000; # bytes, the log table with its indexes
      for = "15m";
    };
  };

  mkRules =
    {
      lib,
      thresholds ? { },
      watchedUnits,
    }:
    let
      t = lib.recursiveUpdate defaults thresholds;

      # `name` is a rule's alert name; the threshold set holds its `for`.
      rule =
        name:
        {
          expr,
          severity,
          summary,
          description,
          rideOutGaps ? true,
        }:
        {
          alert = name;
          inherit expr;
          inherit (t.${name}) for;
          labels = { inherit severity; };
          annotations = { inherit summary description; };
        }
        // lib.optionalAttrs rideOutGaps { keep_firing_for = gapGrace; };
      # Every alert but TargetDown reads an exporter's series. One missed
      # scrape (a deploy restarting node-exporter, a slow cAdvisor) marks
      # those series stale, and the alert would resolve and fire again at the
      # next scrape: a resolved post and a new ping for every standing alert.
      # So a firing alert, event or threshold, stays firing through a gap of
      # up to `gapGrace`, which also delays each resolved post by that much.
      # TargetDown is the exception: `up` is written by every scrape, failed
      # or not, so it has no gaps.
      event = name: args: rule name (args // { severity = "event"; });
      threshold = name: args: rule name (args // { severity = "threshold"; });

      # PromQL raw strings (backticks) keep the regex backslashes as written.
      # Prometheus anchors a regex matcher, so no ^ and $ here.
      unitRegex = lib.concatMapStringsSep "|" (u: lib.escapeRegex "${u}.service") watchedUnits;
      # A failed `notify-failure@` unit means the notifier could not post
      # (Discord is unreachable): a second post would fail the same way and
      # repeat every 12 hours, so UnitFailed skips those too.
      notifyFailure = "notify-failure@.+\\.service";
      notWatched =
        if watchedUnits == [ ] then
          ", name!~`${notifyFailure}`"
        else
          ", name!~`${unitRegex}|${notifyFailure}`";

      # True while the named unit is in the failed state. Its own failure is
      # posted by the notifier or by UnitFailed, so the alerts that would
      # repeat it as a symptom are held back with `unless on()`.
      failed = unit: ''node_systemd_unit_state{name="${unit}.service",state="failed"} == 1'';

      gapGrace = "2m";

      stack = ''id=~"/stack.slice/stack-.+\\.slice"'';
      pct = ''{{ $value | printf "%.0f" }}'';
      thr = name: "${toString t.${name}.value}% for ${t.${name}.for}";
    in
    {
      groups = [
        {
          name = "homeserver-events";
          rules = [
            (event "TargetDown" {
              rideOutGaps = false;
              expr = ''
                (up{job!~"cadvisor|comin|blackbox_.+|dns_.+"} == 0)
                or (up{job=~"blackbox_.+|dns_.+"} == 0 unless on() (${failed "prometheus-blackbox-exporter"}))
                or (up{job="cadvisor"} == 0 unless on() (${failed "cadvisor"}))
                or (up{job="comin"} == 0 unless on() (${failed "comin"}))
              '';
              summary = "Scrape target {{ $labels.job }} is down (for ${t.TargetDown.for})";
              description = "Prometheus cannot scrape {{ $labels.instance }} (job {{ $labels.job }}).";
            })
            (event "UnitFailed" {
              expr = ''node_systemd_unit_state{state="failed"${notWatched}} == 1'';
              summary = "Unit {{ $labels.name }} failed";
              description = "systemd reports {{ $labels.name }} in the failed state. The notifier does not watch this unit.";
            })
            (event "CominFetchFailed" {
              expr = "comin_last_fetch_failed == 1";
              summary = "comin cannot fetch the repository (for ${t.CominFetchFailed.for})";
              description = "comin's last fetch failed, so the host is not following main.";
            })
            (event "CominEvalFailed" {
              expr = "comin_last_eval_failed == 1";
              summary = "comin cannot evaluate the configuration";
              description = "comin's last evaluation failed, so a deploy of the new commit did not start.";
            })
            (event "CominBuildFailed" {
              expr = "comin_last_build_failed == 1";
              summary = "comin cannot build the configuration (for ${t.CominBuildFailed.for})";
              description = "comin's last build failed. comin also reports a build cancelled by a newer commit this way, hence the wait.";
            })
            (event "TailnetDisconnected" {
              expr = ''
                homeserver_tailscale_running == 0
                unless on() (${failed "tailscaled"})
              '';
              summary = "The nuc is not connected to the tailnet (for ${t.TailnetDisconnected.for})";
              description = "Tailscale is not running and logged in.";
            })
            (event "GatewayUnreachable" {
              expr = ''probe_success{job="blackbox_gateway"} == 0'';
              summary = "The LAN gateway does not answer ping (for ${t.GatewayUnreachable.for})";
              description = "The blackbox exporter's ICMP probe of the gateway fails. The LAN is probably down.";
            })
            (event "DnsFailing" {
              expr = ''probe_success{job="blackbox_dns"} == 0'';
              summary = "DNS lookups through the nuc's resolver fail (for ${t.DnsFailing.for})";
              description = "The blackbox exporter's DNS probe fails.";
            })
            (event "DnsServerDown" {
              expr = ''probe_success{job="dns_resolve"} == 0'';
              summary = "DNS server {{ $labels.server }} does not resolve (for ${t.DnsServerDown.for})";
              description = "The blackbox exporter's DNS lookup of example.com against {{ $labels.server }} fails. A dead secondary is noticed only on the day the nuc reboots.";
            })
            (event "DnsServerNotBlocking" {
              expr = ''probe_success{job="dns_blocked"} == 0'';
              summary = "DNS server {{ $labels.server }} does not block (for ${t.DnsServerNotBlocking.for})";
              description = "A name on the blocklists, probed against {{ $labels.server }}, comes back with a real address instead of 0.0.0.0. Its lists may have failed to download.";
            })
            (event "DnsThreatBlocked" {
              expr = "homeserver_dns_threat_blocks > 0";
              summary = "{{ $labels.client }} asked for {{ $labels.domain }}, a name on the threat lists (blocked)";
              description = "Blocky refused a lookup whose name is on a threat list (malware, phishing) in the last 5 minutes. The device may be infected or the user followed a bad link.";
            })
            (event "DnsNewClient" {
              expr = "homeserver_dns_new_client == 1";
              summary = "A new device asked the DNS server for the first time: {{ $labels.client }}";
              description = "The client's first entry in the query log is less than 10 minutes old. A guest, or something that should not be on the network.";
            })
            (event "DnsWatchFailing" {
              # absent(): the file is missing (the timer never ran).
              expr = "homeserver_dns_watch_success == 0 or absent(homeserver_dns_watch_success)";
              summary = "The DNS query-log watch is not running (for ${t.DnsWatchFailing.for})";
              description = "The dns-watch timer's queries fail or its file is missing, so the threat, NXDOMAIN and new-client alerts are blind.";
            })
            (event "OomKill" {
              # Named containers only: cgroup v2 counts a kill in memory.events
              # of every ancestor too, so the stack slice, /stack.slice and the
              # root would each raise the same alert.
              expr = ''increase(container_oom_events_total{name!=""}[5m]) > 0'';
              summary = "Out-of-memory kill in container {{ $labels.name }}";
              description = "The kernel killed a process for running out of memory in container {{ $labels.name }} (cAdvisor's container_oom_events_total rose in the last 5 minutes).";
            })
          ];
        }
        {
          name = "homeserver-dns";
          rules = [
            (threshold "DnsNxdomainBurst" {
              # Both conditions on the same client. The baseline is 0 for a
              # client with no history, so its first burst counts.
              expr = ''
                homeserver_dns_nxdomain_recent > ${toString t.DnsNxdomainBurst.value}
                  and
                homeserver_dns_nxdomain_recent > ${toString t.DnsNxdomainBurst.factor} * homeserver_dns_nxdomain_baseline
              '';
              summary = "{{ $labels.client }} gets ${pct} NXDOMAIN answers a minute (threshold above ${toString t.DnsNxdomainBurst.value} a minute and ${toString t.DnsNxdomainBurst.factor} times its baseline, for ${t.DnsNxdomainBurst.for})";
              description = "A device is asking for many names that do not exist, as malware generating domain names does.";
            })
            (threshold "DnsQueryLogLarge" {
              expr = "homeserver_dns_querylog_bytes > ${toString t.DnsQueryLogLarge.value}";
              summary = "The DNS query log is {{ $value | humanize }}B (threshold above ${
                toString (t.DnsQueryLogLarge.value / 1000000000)
              } GB for ${t.DnsQueryLogLarge.for})";
              description = "Blocky's query log table in PostgreSQL is growing past what 14 days of use should need. The hard cap (homeserver.dns.queryLogMaxBytes) will delete the oldest rows, so look for a client that floods the server.";
            })
          ];
        }
        {
          name = "homeserver-host";
          rules = [
            (threshold "DiskFilling" {
              expr = ''
                100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})
                  > ${toString t.DiskFilling.value}
              '';
              summary = "Disk / is ${pct}% full (threshold ${thr "DiskFilling"})";
              description = "The one btrfs filesystem, holding /, /srv, /nix and Docker's data, is filling up.";
            })
            (threshold "HostMemoryLow" {
              expr = ''
                100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
                  < ${toString t.HostMemoryLow.value}
              '';
              summary = "Available memory is ${pct}% (threshold below ${thr "HostMemoryLow"})";
              description = "The host has little memory left for new work.";
            })
            (threshold "HostCpuHigh" {
              expr = ''
                100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))
                  > ${toString t.HostCpuHigh.value}
              '';
              summary = "CPU is ${pct}% busy across all cores (threshold ${thr "HostCpuHigh"})";
              description = "All cores together have been busy for a long spell.";
            })
            (threshold "TemperatureHigh" {
              expr = ''
                (node_hwmon_temp_celsius >= on(chip, sensor) (node_hwmon_temp_crit_celsius - ${toString t.TemperatureHigh.value}))
                or
                (node_hwmon_temp_celsius >= ${toString t.TemperatureHigh.fallback} unless on(chip, sensor) node_hwmon_temp_crit_celsius)
              '';
              summary = "Sensor {{ $labels.chip }}/{{ $labels.sensor }} is at ${pct} °C (threshold ${toString t.TemperatureHigh.value} °C below its crit mark, or ${toString t.TemperatureHigh.fallback} °C without one, for ${t.TemperatureHigh.for})";
              description = "A hardware sensor is close to the limit its own chip reports.";
            })
          ];
        }
        {
          name = "homeserver-stacks";
          rules = [
            (threshold "ContainerCpuHigh" {
              expr = ''
                100 * rate(container_cpu_usage_seconds_total{name!=""}[5m])
                  / scalar(count(node_cpu_seconds_total{mode="idle"}))
                  > ${toString t.ContainerCpuHigh.value}
              '';
              summary = "Container {{ $labels.name }} uses ${pct}% of the host's CPU (threshold ${thr "ContainerCpuHigh"})";
              description = "One container has taken a large share of all cores for a long spell.";
            })
            (threshold "StackMemoryNearLimit" {
              expr = ''
                100 * container_memory_working_set_bytes{${stack}}
                  / on(id, instance) (container_spec_memory_limit_bytes{${stack}} > 0)
                  > ${toString t.StackMemoryNearLimit.value}
              '';
              summary = "Stack slice {{ $labels.id }} uses ${pct}% of its memory limit (threshold ${thr "StackMemoryNearLimit"})";
              description = "The slice is near its memoryMax, so the kernel may start killing its processes.";
            })
            (threshold "StackMemoryStalled" {
              expr = ''
                100 * rate(container_pressure_memory_waiting_seconds_total{${stack}}[5m])
                  > ${toString t.StackMemoryStalled.value}
              '';
              summary = "Stack slice {{ $labels.id }} is stalled on memory ${pct}% of the time (threshold ${thr "StackMemoryStalled"})";
              description = "Processes in the slice wait for memory (pressure stall information, \"some\").";
            })
            (threshold "StackCpuStarved" {
              expr = ''
                100 * rate(container_pressure_cpu_waiting_seconds_total{${stack}}[5m])
                  > ${toString t.StackCpuStarved.value}
              '';
              summary = "Stack slice {{ $labels.id }} waits for CPU ${pct}% of the time (threshold ${thr "StackCpuStarved"})";
              description = "Processes in the slice are ready to run but wait for a core (pressure stall information, \"some\").";
            })
          ];
        }
      ];
    };
in
{
  inherit defaults mkRules;
}
