# The tenant's job runner, ticket 6.9 (#199); ADR (Architecture Decision
# Record) 0013. A guest module: `homeserver.tenants.vms.<name>.runner` adds
# it to that VM (tenant-run), and tests/tenant-runner.nix runs it on a plain
# test node.
#
#  - tenant-runner-keys makes the VM's two keys on first boot, in /var: an
#    SSH deploy key, which reads the tenant's private repo, and an age key,
#    which decrypts its secrets/prod.yaml. Neither leaves the VM; their public
#    halves are in /var/lib/tenant-runner/{deploy_key,age}.pub for Alex to add
#    to the repo (docs/runbooks/tenants.md). Losing /var makes new ones.
#  - tenant-deploy, every 5 minutes (./deploy.sh): fetch `main`, check that
#    its CI passed on GitHub (the production gate), decrypt the secrets into
#    a file only the run can read, `docker compose up` the tenant's stack.
#    Nothing happens while `main` is unchanged and deployed.
#  - A failed deploy posts its log tail to the tenant's webhook
#    (./deploy-failed.sh), once per commit. A failure to fetch or decrypt is
#    the platform's and alerts Alex through the metrics instead.
#  - node-exporter serves the deploy's metrics and the jobs' (from the
#    repo's `run-job` wrapper) to the host's Prometheus, and the size of
#    /var, and nothing else about the VM.
#
# The stack gets two variables for its compose file: TENANT_SECRETS, the
# decrypted dotenv file (for `env_file:`), and TENANT_JOB_METRICS, the
# directory a job writes `<job>.prom` into (for a bind mount). Docker keeps
# the secrets in its containers' configuration on /var, as it does for any
# `env_file`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.tenantRunner;
  state = "/var/lib/tenant-runner";
  nodePort = 9100;

  deploy = pkgs.writeShellApplication {
    name = "tenant-deploy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.git
      pkgs.openssh
      pkgs.sops
      pkgs.curl
      pkgs.jq
      config.virtualisation.docker.package
    ];
    text = builtins.readFile ./deploy.sh;
  };
  deployFailed = pkgs.writeShellApplication {
    name = "tenant-deploy-failed";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      config.systemd.package
    ];
    text = builtins.readFile ./deploy-failed.sh;
  };
  # Only the jobs' own series, one sample a line: a job's file can't name a
  # deploy series, and a malformed line can't break the collector's other
  # files. The tenant controls the stack, so this keeps out mistakes, not
  # intent (ADR 0013).
  jobMetrics = pkgs.writeShellApplication {
    name = "tenant-job-metrics";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      out=${state}/metrics/tenant_jobs.prom
      find ${state}/job-metrics -maxdepth 1 -name '*.prom' -type f -exec cat {} + |
        { grep -E '^tenant_job_[a-z_]+\{job="[A-Za-z0-9_.-]+"\} [0-9.eE+-]+$' || true; } |
        sort -u >"$out.tmp"
      chmod 0644 "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
in
{
  options.homeserver.tenantRunner = {
    repoUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A file holding the URL of the repository to deploy. Null: the system
        credential `repo-url`, which the host passes into the VM from sops.
      '';
    };
    ciTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A file holding a read-only GitHub token for the repository's Actions
        runs, which the deploy checks before deploying a commit. Null: the
        system credential `ci-token`, which the host passes into the VM from
        sops.
      '';
    };
    ciApi = lib.mkOption {
      type = lib.types.str;
      default = "https://api.github.com";
      description = "GitHub's API, asked whether a commit's CI (continuous integration) passed.";
    };
    ciRepo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The repository's `owner/name` on GitHub. Null: taken from its URL.";
    };
    scrapeFrom = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The address node-exporter's port is opened to: the host's.";
    };
  };

  config = {
    virtualisation.docker = {
      enable = true;
      # Rotated on disk, as the host's journald rotates its containers' logs.
      daemon.settings.log-driver = "local";
    };

    environment.systemPackages = [
      pkgs.git
      pkgs.sops
    ];

    systemd.tmpfiles.settings."10-tenant-runner" = {
      ${state}.d.mode = "0755";
      "${state}/metrics".d.mode = "0755";
      # Written by the tenant's containers.
      "${state}/job-metrics".d.mode = "0777";
      "/run/tenant-runner".d.mode = "0700";
    };

    systemd.services.tenant-runner-keys = {
      description = "Make tenant-run's deploy key and age key, once";
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.openssh
        pkgs.age
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        keys=${state}/keys
        mkdir -p "$keys"
        if [ ! -e "$keys/deploy_key" ]; then
          rm -f "$keys/deploy_key.new" "$keys/deploy_key.new.pub"
          ssh-keygen -q -t ed25519 -N "" -C tenant-run -f "$keys/deploy_key.new"
          mv "$keys/deploy_key.new.pub" "$keys/deploy_key.pub"
          mv "$keys/deploy_key.new" "$keys/deploy_key"
        fi
        if [ ! -e "$keys/age.key" ]; then
          # Left by an interrupted first boot; age-keygen won't overwrite it.
          rm -f "$keys/age.key.new"
          age-keygen -o "$keys/age.key.new"
          mv "$keys/age.key.new" "$keys/age.key"
        fi
        install -m 0644 "$keys/deploy_key.pub" ${state}/deploy_key.pub
        age-keygen -y "$keys/age.key" >${state}/age.pub
        chmod 0644 ${state}/age.pub
        echo "deploy key: $(cat ${state}/deploy_key.pub)"
        echo "age recipient: $(cat ${state}/age.pub)"
      '';
    };

    # GitHub's published host key, so the first fetch can't be intercepted.
    programs.ssh.knownHosts."github.com".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    systemd.services.tenant-deploy = {
      description = "Deploy the tenant's main branch";
      requires = [ "tenant-runner-keys.service" ];
      after = [
        "tenant-runner-keys.service"
        "docker.service"
        "network-online.target"
      ];
      wants = [
        "docker.service"
        "network-online.target"
      ];
      onFailure = [ "tenant-deploy-failed.service" ];
      # Not restarted by a rebuild; the timer runs it.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe deploy;
        LoadCredential = [
          ("repo-url" + lib.optionalString (cfg.repoUrlFile != null) ":${cfg.repoUrlFile}")
          ("ci-token" + lib.optionalString (cfg.ciTokenFile != null) ":${cfg.ciTokenFile}")
        ];
        Environment = [
          "TENANT_CI_API=${cfg.ciApi}"
        ]
        ++ lib.optional (cfg.ciRepo != null) "TENANT_CI_REPO=${cfg.ciRepo}";
        RuntimeDirectory = "tenant-deploy";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        # A build of the tenant's images may be slow; a hung one is not.
        TimeoutStartSec = "30min";
      };
    };
    systemd.timers.tenant-deploy = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitInactiveSec = "5min";
      };
    };

    systemd.services.tenant-deploy-failed = {
      description = "Post a failed deploy to the tenant's webhook";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe deployFailed;
      };
    };

    systemd.services.tenant-job-metrics = {
      description = "Copy the tenant's job metrics to node-exporter";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe jobMetrics;
      };
    };
    systemd.timers.tenant-job-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "minutely";
    };

    services.prometheus.exporters.node = {
      enable = true;
      port = nodePort;
      # The deploy's and the jobs' files, and /var's size; nothing else.
      enabledCollectors = [
        "textfile"
        "filesystem"
      ];
      extraFlags = [
        "--collector.disable-defaults"
        "--collector.textfile.directory=${state}/metrics"
        "--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|nix)($|/)"
      ];
    };
    networking.firewall.extraInputRules = lib.mkIf (cfg.scrapeFrom != null) ''
      ip saddr ${cfg.scrapeFrom} tcp dport ${toString nodePort} accept
    '';
  };
}
