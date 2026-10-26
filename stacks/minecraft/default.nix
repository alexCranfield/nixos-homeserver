# The `minecraft` stack: see compose.yml. Ticket 4.1 (#28).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  whitelistSync = pkgs.writeShellApplication {
    name = "minecraft-whitelist";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = builtins.readFile ./whitelist-sync.sh;
  };
in
{
  homeserver.stacks.minecraft = {
    composeFile = ./compose.yml;
    services = [ "server" ];
    # Friends reach it only through Tailscale sharing (ADR 0011).
    publicPorts = [
      {
        port = 25565;
        interface = "tailscale0";
      }
    ];
    dataDir = "/srv/data/minecraft";
    uid = 40001;
    gid = 40001;
    # MEMORY in compose.yml is the heap; the rest is the JVM's (Java virtual
    # machine's) own memory.
    # The pack used 14.5 GiB idle, before anyone joined (docs/runbooks/
    # minecraft.md has the timing run).
    resources.memoryMax = "18G";
    # Writes paused and flushed, so the snapshot holds a whole world. A
    # stopped server is snapshotted without these.
    snapshot = {
      preCommand = ''
        set -e
        # Running is not ready: after a crash or a reboot Docker restarts the
        # server outside the stack's lock, and RCON (remote console) comes up
        # only when it has loaded, which took 96 seconds in the timing run.
        health() { docker inspect -f '{{.State.Health.Status}}' minecraft-server-1; }
        for _ in $(seq 60); do [ "$(health)" = healthy ] && break; sleep 5; done
        [ "$(health)" = healthy ]
        docker exec minecraft-server-1 rcon-cli save-off
        docker exec minecraft-server-1 rcon-cli save-all flush
      '';
      postCommand = "docker exec minecraft-server-1 rcon-cli save-on";
    };
  };

  # Only while the stack is declared: the VM tests that replace the host's
  # stacks also drop its user, and have no secrets to decrypt.
  sops.secrets = lib.mkIf (config.homeserver.stacks ? minecraft) {
    # The CurseForge API (application programming interface) key the image downloads the pack with, mounted into
    # the container as a compose secret and read as the stack's own user.
    minecraft-cf-api-key = {
      sopsFile = ../../secrets/minecraft.yaml;
      key = "CF_API_KEY";
      owner = config.users.users.stack-minecraft.name;
      restartUnits = [ "stack-minecraft.service" ];
    };

    # The whitelist: a `WHITELIST=` line of comma-separated names under the
    # `env` key, which predates #153. Only minecraft-whitelist.service reads
    # it, as root; the stack has no .env, so a change recreates nothing.
    minecraft-env = {
      sopsFile = ../../secrets/minecraft.yaml;
      key = "env";
      restartUnits = [ "minecraft-whitelist.service" ];
    };
  };

  # Applies that list to the running server (whitelist-sync.sh): when the
  # secret changes, and after each start of the stack, so a server started
  # from an older snapshot or a fresh world ends up with the same names.
  systemd.services.minecraft-whitelist = lib.mkIf (config.homeserver.stacks ? minecraft) {
    description = "Apply the Minecraft whitelist from secrets/minecraft.yaml";
    after = [ "stack-minecraft.service" ];
    wantedBy = [
      "stack-minecraft.service"
      "multi-user.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe whitelistSync} ${config.sops.secrets.minecraft-env.path} minecraft-server-1";
      # It waits up to five minutes for the server to be ready.
      TimeoutStartSec = "10min";
    };
  };
  homeserver.notify.units = lib.mkIf (config.homeserver.stacks ? minecraft) [ "minecraft-whitelist" ];
}
