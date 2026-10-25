# The `minecraft` stack: see compose.yml. Ticket 4.1 (#28).
{ config, ... }:
{
  homeserver.stacks.minecraft = {
    composeFile = ./compose.yml;
    services = [ "server" ];
    envSecret = "minecraft-env";
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
    # MEMORY in compose.yml is the heap; the rest is the JVM's own memory.
    resources.memoryMax = "15G";
    # Writes paused and flushed, so the snapshot holds a whole world. A
    # stopped server is snapshotted without these.
    snapshot = {
      preCommand = ''
        set -e
        docker exec minecraft-server-1 rcon-cli save-off
        docker exec minecraft-server-1 rcon-cli save-all flush
      '';
      postCommand = "docker exec minecraft-server-1 rcon-cli save-on";
    };
  };

  # The CurseForge API key the image downloads the pack with, mounted into
  # the container as a compose secret and read as the stack's own user.
  sops.secrets.minecraft-cf-api-key = {
    sopsFile = ../../secrets/minecraft.yaml;
    key = "CF_API_KEY";
    owner = config.users.users.stack-minecraft.name;
    restartUnits = [ "stack-minecraft.service" ];
  };

  # The stack's .env: dotenv lines, such as the whitelist, under the `env`
  # key. Compose reads it as root, so it keeps sops-nix's default owner.
  sops.secrets.minecraft-env = {
    sopsFile = ../../secrets/minecraft.yaml;
    key = "env";
  };
}
