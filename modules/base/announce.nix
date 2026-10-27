# Public status messages, ticket #161: what everyone who uses the nuc should
# know, to a second Discord webhook and into the Minecraft servers' chat.
# notify.nix's channel stays Alex's own, for failures and their logs.
#
# What posts. Discord gets each with its icon and the time in UTC
# (Coordinated Universal Time); the game gets the text, with the link as a
# clickable "More info":
#
#  - comin is about to deploy a merge: "Applying update", with the pull
#    request. From comin's build hook, which runs before it deploys (comin
#    has no hook of its own for that). Every update gets the same wording,
#    whether or not it restarts anything (Alex, 2026-10-27).
#  - The deploy finished: "Update complete".
#  - The deploy failed: "Update failed", Discord only; the error goes to the
#    private channel. Either only for an update announced as applying
#    (announce-comin.sh says why).
#  - The reboot window is about to reboot: a warning `rebootWarning` seconds
#    ahead, and a reminder in game a minute before. Only when a reboot is
#    pending: the window checks first (reboot-window.nix).
#  - The host is up, after any boot: Discord only, as nobody is in game yet.
#  - `sudo nuc-announce "TEXT" [LINK]`, for anything else, such as planned
#    maintenance.
#
# Public messages carry no log, unit name, hostname or kernel version, and
# mention no one: the role in notify.nix is never pinged from here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.announce;

  announce = pkgs.writeShellApplication {
    name = "homeserver-announce";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.jq
      config.homeserver.notify.sender
    ]
    ++ lib.optional (cfg.minecraftContainers != [ ]) config.virtualisation.docker.package;
    text = ''
      ANNOUNCE_WEBHOOK=${lib.escapeShellArg cfg.webhookFile}
      ANNOUNCE_CONTAINERS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.minecraftContainers)}
    ''
    + builtins.readFile ./announce.sh;
  };

  cominHook = pkgs.writeShellApplication {
    name = "announce-comin";
    runtimeInputs = [
      pkgs.coreutils
      announce
    ];
    # Overridable for tests/announce.nix, which has no comin build to point
    # at.
    text = ''
      ANNOUNCE_GCROOT=''${ANNOUNCE_GCROOT:-/var/lib/comin/gcroots/last-built-generation}
      ANNOUNCE_CURRENT=''${ANNOUNCE_CURRENT:-/run/current-system}
      ANNOUNCE_STATE=''${ANNOUNCE_STATE:-/run/announce-comin}
    ''
    + builtins.readFile ./announce-comin.sh;
  };

  # announce-reboot [SECONDS]: warn, then wait for the reboot to be due.
  rebootWarning = pkgs.writeShellApplication {
    name = "announce-reboot";
    runtimeInputs = [
      pkgs.coreutils
      announce
    ];
    text = ''
      warning=''${1:-${toString cfg.rebootWarning}}
      minutes=$(((warning + 59) / 60))
      unit=minutes
      if [ "$minutes" = 1 ]; then unit=minute; fi
      at=$(date -u -d "+$warning seconds" +%H:%M)
      homeserver-announce 🟠 "Scheduled maintenance: the nuc restarts at $at UTC (in $minutes $unit)." || true
      if [ "$warning" -gt 60 ]; then
        sleep $((warning - 60))
        warning=60
      fi
      homeserver-announce --game-only 🟠 "The nuc restarts in 1 minute." || true
      sleep "$warning"
    '';
  };

  nucAnnounce = pkgs.writeShellApplication {
    name = "nuc-announce";
    runtimeInputs = [ announce ];
    text = ''
      if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        echo 'usage: sudo nuc-announce "TEXT" [LINK]' >&2
        exit 2
      fi
      exec homeserver-announce 📢 "$1" "''${2:-}"
    '';
  };
in
{
  options.homeserver.announce = {
    webhookFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File holding the public Discord webhook URL, decrypted at activation
        (sops), never a store path. null turns public messages off.
      '';
    };
    minecraftContainers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "minecraft-server-1" ];
      description = ''
        Containers running a Minecraft server with `rcon-cli`, whose chat
        shows the messages too. Each Minecraft stack adds its own.
      '';
    };
    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/alexCranfield/nixos-homeserver";
      description = "Where an update's pull request or commit is linked to.";
    };
    rebootWarning = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds between the reboot window's warning and its reboot.";
    };
    announcer = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = announce;
      description = ''
        `homeserver-announce [--game-only|--discord-only] ICON TEXT [LINK]`,
        for posters outside this module.
      '';
    };
  };

  config = lib.mkIf (cfg.webhookFile != null) {
    assertions = [
      {
        assertion = !lib.hasPrefix builtins.storeDir cfg.webhookFile;
        message = "homeserver.announce: ${cfg.webhookFile} is in the Nix store, which every local user can read.";
      }
    ];

    homeserver.comin.postBuild = [ "${lib.getExe cominHook} ${lib.escapeShellArg cfg.repoUrl}" ];
    homeserver.comin.postDeployment = [ "${lib.getExe cominHook} ${lib.escapeShellArg cfg.repoUrl}" ];

    # The window reboots at 10:00 UTC, Alex's choice (reboot-window.nix):
    # its timer starts five minutes early, for the warning.
    homeserver.rebootWindow.calendar = lib.mkDefault "Tue *-*-* 09:55:00";
    homeserver.rebootWindow.preReboot = [ (lib.getExe rebootWarning) ];

    systemd.services.announce-online = {
      description = "Post to the public channel that the host is up";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # A deploy that changes this unit must not post that the host is up.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # The deploy that adds this unit starts it too, long after boot.
      script = ''
        read -r up _ < /proc/uptime
        if [ "''${up%.*}" -gt 600 ]; then
          echo "up for ''${up%.*} s: started by a deploy, not a boot; not posting"
          exit 0
        fi
        ${lib.getExe announce} --discord-only 🟢 "The nuc is back up." ||
          echo "could not post the boot message" >&2
      '';
    };

    environment.systemPackages = [ nucAnnounce ];
  };
}
