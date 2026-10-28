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
# Everything listens on 127.0.0.1 only. Port 8080, cAdvisor's default, is the
# hello stack's, so cAdvisor takes 8081.
{ ... }:
let
  ports = {
    prometheus = 9090;
    node = 9100;
    cadvisor = 8081;
    # Fixed by comin; its address is set in modules/base/comin.nix.
    comin = 4243;
  };
  scrape = job: port: {
    job_name = job;
    static_configs = [ { targets = [ "127.0.0.1:${toString port}" ]; } ];
  };
in
{
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
}
