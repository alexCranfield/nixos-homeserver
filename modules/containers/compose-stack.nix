# Compose stacks as systemd units, ticket 3.2 (#23); ADR (Architecture
# Decision Record) 0002 for why Compose, 0006 for the rules on ports.
#
# `homeserver.stacks.<name>` turns a compose file into `stack-<name>.service`,
# which runs `docker compose up` when it starts and `down` when it stops. The
# files go to /etc/stacks/<name>/:
#
#  - compose.yml, the stack's file as written, so upstream examples apply;
#  - override.yml, generated, which Compose merges over it: every service
#    restarts unless stopped, and runs in the stack's slice;
#  - .env, a link to the stack's sops secret, if it has one. Compose reads it
#    for `${VAR}` in the file; a service gets it as environment only with
#    `env_file: .env`.
#
# Two things are less obvious than they look:
#
#  - The unit wants Docker, but does not require it. A deploy that changes
#    Docker restarts docker.service, and `Requires=` would stop each stack
#    with it, which runs `down`. With `live-restore` (modules/containers/
#    docker.nix) the containers outlive the restart, so the stacks do too.
#  - Public ports are enforced on the forward path. Docker redirects a
#    published port before the NixOS input rules see it, and NixOS's forward
#    chain accepts whatever Docker redirected. The `stack-ports` table runs
#    first and drops any redirected connection to a port no stack declares,
#    or arriving anywhere but `publicInterface`, logging each new connection
#    either way. The input rules list the declared ports too, so the NixOS
#    firewall configuration still reads as the list of what is public.
#  - Limits go on a slice, not on the unit. Docker starts containers under
#    containerd, so `MemoryMax=` on the unit would limit only the `docker
#    compose` client. `stack-<name>.slice` carries them, and the override's
#    `cgroup_parent` puts the containers in it. A dash in the name nests the
#    slice: stack-fixture.slice sits under stack.slice.
#
# Day-to-day use: docs/runbooks/stacks.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.stacks;

  portType = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.port;
        description = "Port number, the same on the host and published.";
      };
      protocol = lib.mkOption {
        type = lib.types.enum [
          "tcp"
          "udp"
        ];
        default = "tcp";
      };
      allowedSources = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [ "203.0.113.7/32" ];
        description = "IPv4 addresses or ranges allowed in; null lets anyone in.";
      };
    };
  };

  stackType = lib.types.submodule {
    options = {
      composeFile = lib.mkOption {
        type = lib.types.path;
        description = "The stack's compose file, used as written.";
      };
      services = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        description = ''
          The compose file's service names, for the generated override. The
          flake check over stacks/ fails if they differ from the file's.
        '';
      };
      envSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of the sops secret that becomes the stack's .env.";
      };
      publicPorts = lib.mkOption {
        type = lib.types.listOf portType;
        default = [ ];
        description = ''
          Ports open to `homeserver.publicInterface`, IPv4 only. The compose
          file must publish each as `0.0.0.0:<port>:<container port>`.
        '';
      };
      dataDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/srv/data/minecraft";
        description = "The stack's data directory; bind mounts must sit under it.";
      };
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start the stack at boot.";
      };
      resources = {
        memoryMax = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "8G";
          description = "systemd MemoryMax= for all of the stack's containers.";
        };
        cpuWeight = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "systemd CPUWeight= for the stack's containers; 100 is the default.";
        };
      };
      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Further units to start after, such as a mount.";
      };
    };
  };

  dir = name: "/etc/stacks/${name}";

  # The settings every service gets, merged over the compose file.
  override =
    name: stack:
    pkgs.writeText "override.yml" (
      builtins.toJSON {
        services = lib.genAttrs stack.services (_: {
          restart = "unless-stopped";
          cgroup_parent = "stack-${name}.slice";
        });
      }
    );

  ports = lib.concatLists (lib.mapAttrsToList (_: s: s.publicPorts) cfg);

  # Two rules per declared port, as nft limits: the first logs (at most 10
  # a minute, bursts of 5), the second accepts. A limit that runs out only
  # stops the logging.
  portRules =
    p:
    let
      match =
        ''ct state new ct status dnat iifname "${config.homeserver.publicInterface}"''
        + " meta l4proto ${p.protocol} ct original proto-dst ${toString p.port}"
        + lib.optionalString (
          p.allowedSources != null
        ) " ip saddr { ${lib.concatStringsSep ", " p.allowedSources} }";
    in
    ''
      ${match} limit rate 10/minute burst 5 packets log prefix "stack-port accept ${toString p.port}/${p.protocol} "
      ${match} counter accept
    '';

  # After `up`: each declared port is listening on every IPv4 address, or
  # the unit fails, so a port that did not bind is reported.
  checkPorts =
    name: stack:
    pkgs.writeShellScript "stack-${name}-ports" (
      lib.concatMapStrings (p: ''
        if ! ${pkgs.iproute2}/bin/ss -Hln${
          if p.protocol == "tcp" then "t" else "u"
        } 'sport = :${toString p.port}' | grep -q ' 0\.0\.0\.0:${toString p.port} '; then
          echo "${toString p.port}/${p.protocol} is declared public but not listening on 0.0.0.0" >&2
          exit 1
        fi
      '') stack.publicPorts
    );

  compose =
    name: verb:
    "${lib.getExe pkgs.docker} compose --project-name ${name} --project-directory ${dir name}"
    + " --file ${dir name}/compose.yml --file ${dir name}/override.yml ${verb}";
in
{
  options.homeserver = {
    stacks = lib.mkOption {
      type = lib.types.attrsOf stackType;
      default = { };
      description = "Compose stacks, each run by `stack-<name>.service`.";
    };
    publicInterface = lib.mkOption {
      type = lib.types.str;
      default = "lan0";
      description = "The interface public ports are open on.";
    };
    stacksManifest = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "What the flake check over stacks/ compares compose files with.";
    };
  };

  config = {
    homeserver.stacksManifest = lib.mapAttrs (_: s: {
      composeFile = "${s.composeFile}";
      inherit (s) services dataDir;
      publicPorts = map (p: { inherit (p) port protocol; }) s.publicPorts;
    }) cfg;

    environment.etc = lib.concatMapAttrs (
      name: stack:
      {
        "stacks/${name}/compose.yml".source = stack.composeFile;
        "stacks/${name}/override.yml".source = override name stack;
      }
      // lib.optionalAttrs (stack.envSecret != null) {
        "stacks/${name}/.env".source = config.sops.secrets.${stack.envSecret}.path;
      }
    ) cfg;

    # sops-nix restarts the stack when the secret's content changes, which
    # restartTriggers cannot see: the content is decrypted at activation.
    sops.secrets = lib.concatMapAttrs (
      name: stack:
      lib.optionalAttrs (stack.envSecret != null) {
        ${stack.envSecret}.restartUnits = [ "stack-${name}.service" ];
      }
    ) cfg;

    systemd.slices = lib.mapAttrs' (
      name: stack:
      lib.nameValuePair "stack-${name}" {
        description = "Containers of the ${name} stack";
        sliceConfig =
          lib.optionalAttrs (stack.resources.memoryMax != null) {
            MemoryMax = stack.resources.memoryMax;
          }
          // lib.optionalAttrs (stack.resources.cpuWeight != null) {
            CPUWeight = stack.resources.cpuWeight;
          };
      }
    ) cfg;

    systemd.services = lib.mapAttrs' (
      name: stack:
      lib.nameValuePair "stack-${name}" {
        description = "Compose stack ${name}";
        wants = [
          "docker.service"
          "network-online.target"
        ];
        after = [
          "docker.service"
          "network-online.target"
        ]
        ++ stack.after;
        wantedBy = lib.optional stack.autoStart "multi-user.target";
        restartTriggers = [
          stack.composeFile
          (override name stack)
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # `--wait`: until each container runs, or is healthy if it has a
          # healthcheck, so one that exits at once fails the unit. First
          # starts pull images.
          ExecStart = compose name "up --detach --remove-orphans --wait";
          ExecStartPost = lib.mkIf (stack.publicPorts != [ ]) (checkPorts name stack);
          ExecStop = compose name "down";
          TimeoutStartSec = "15min";
        };
      }
    ) cfg;

    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (
        _: stack: lib.optional (stack.dataDir != null) "d ${stack.dataDir} 0750 root root - -"
      ) cfg
    );

    networking.firewall.interfaces.${config.homeserver.publicInterface} = {
      allowedTCPPorts = map (p: p.port) (lib.filter (p: p.protocol == "tcp") ports);
      allowedUDPPorts = map (p: p.port) (lib.filter (p: p.protocol == "udp") ports);
    };

    # Before NixOS's own forward chain (priority filter), whose accept for
    # redirected traffic cannot undo a drop here.
    networking.nftables.tables.stack-ports = lib.mkIf (cfg != { }) {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter - 10; policy accept;
          ${lib.concatMapStrings portRules ports}
          ct state new ct status dnat limit rate 10/minute burst 5 packets log prefix "stack-port drop "
          ct state new ct status dnat counter drop
        }
      '';
    };

    homeserver.notify.units = map (name: "stack-${name}") (lib.attrNames cfg);
  };
}
