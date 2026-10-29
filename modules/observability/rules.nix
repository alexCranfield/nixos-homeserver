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
          rideOutGaps ? false,
        }:
        {
          alert = name;
          inherit expr;
          inherit (t.${name}) for;
          labels = { inherit severity; };
          annotations = { inherit summary description; };
        }
        // lib.optionalAttrs rideOutGaps { keep_firing_for = gapGrace; };
      # Event alerts read an exporter's series. One missed scrape (a deploy
      # restarting node-exporter, a slow cAdvisor) marks those series stale,
      # and the alert would resolve and fire again at the next scrape: a
      # resolved post and a new ping for every standing alert. So a firing
      # event alert stays firing through a gap of up to `gapGrace`, which
      # also delays each resolved post by that much. TargetDown is the
      # exception: `up` is written by every scrape, failed or not, so it has
      # no gaps.
      event = name: args: rule name ({ rideOutGaps = true; } // args // { severity = "event"; });
      threshold = name: args: rule name (args // { severity = "threshold"; });

      # PromQL raw strings (backticks) keep the regex backslashes as written.
      # Prometheus anchors a regex matcher, so no ^ and $ here.
      unitRegex = lib.concatMapStringsSep "|" (u: lib.escapeRegex "${u}.service") watchedUnits;
      notWatched = lib.optionalString (watchedUnits != [ ]) ", name!~`${unitRegex}`";

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
                (up{job!~"cadvisor|comin"} == 0)
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
