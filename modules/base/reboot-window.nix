# Reboots for kernel updates happen in a weekly window, ticket 2.3 (#18).
#
# comin switches to each new configuration as soon as it merges (comin.nix),
# but a new kernel, initrd or set of kernel modules only takes effect at the
# next boot. Rather than rebooting at deploy time, possibly mid-game, the timer
# below reboots in the window, and only if the running system's kernel, initrd
# or modules differ from the booted one: the same comparison nixpkgs'
# system.autoUpgrade makes before it reboots. A configuration-only change
# needs no reboot and gets none.
#
# Tuesday 10:00 UTC (Coordinated Universal Time), Alex's choice (2026-10-21):
# 04:00 Mountain daylight time, 03:00 standard, the day after the weekly
# flake.lock pull request (docs/runbooks/updates.md). The clock is UTC
# (system.nix), so the window does not move with daylight saving.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.rebootWindow;
in
{
  options.homeserver.rebootWindow = {
    calendar = lib.mkOption {
      type = lib.types.str;
      default = "Tue *-*-* 10:00:00";
      description = "When to reboot, if a reboot is pending (systemd.time(7)).";
    };
    preReboot = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/run/current-system/sw/bin/broadcast-reboot-warning" ];
      description = ''
        Commands run in order just before a window reboot, for example to warn
        players and wait (game servers, #31). A failing command is logged and
        does not stop the reboot: a security fix should not wait on a chat
        message.
      '';
    };
  };

  config = {
    # comin owns deploys (ADR 0003); stated so nobody enables it beside comin.
    system.autoUpgrade.enable = false;

    systemd.services.reboot-window = {
      description = "Reboot if the kernel changed since boot";
      # comin is off in `just vm`, where its package is unset.
      path = [
        pkgs.coreutils
        pkgs.jq
      ]
      ++ lib.optional config.services.comin.enable config.services.comin.package;
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        parts() { readlink "$1"/initrd "$1"/kernel "$1"/kernel-modules; }
        if [ "$(parts /run/booted-system)" = "$(parts /run/current-system)" ]; then
          echo "kernel, initrd and modules unchanged since boot: no reboot"
          exit 0
        fi
        echo "the running system's kernel, initrd or modules differ from the booted ones"

        # Do not reboot under a deploy in progress: wait up to 30 minutes for
        # comin to finish. If comin cannot be asked, go ahead.
        for _ in $(seq 60); do
          if comin status --json | jq -e '.deployer.is_deploying == true' >/dev/null; then
            echo "comin is deploying; waiting"
            sleep 30
          else
            break
          fi
        done

        ${lib.concatMapStrings (cmd: ''
          echo "pre-reboot: ${cmd}"
          ${cmd} || echo "pre-reboot command failed (exit $?); rebooting anyway"
        '') cfg.preReboot}
        echo "rebooting"
        systemctl reboot
      '';
    };

    systemd.timers.reboot-window = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.calendar;
        # A missed window is not made up at boot: the boot itself has already
        # done what the reboot was for.
        Persistent = false;
      };
    };
  };
}
