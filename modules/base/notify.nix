# Notifications to Discord, ticket 2.5 (#20).
#
# What posts, and whether it pings the role in `roleFile`:
#
#  - A unit in `homeserver.notify.units` fails: systemd's OnFailure= starts
#    `notify-failure@<unit>.service`, which posts the unit's name and its last
#    20 journal lines. Pings.
#  - comin's deployment fails: comin runs `postDeploymentCommand` after every
#    deployment, and a failed one posts the commit and comin's error. comin
#    keeps running when a deployment fails, so OnFailure= on comin would not
#    see it. Pings.
#  - The host comes up: `notify-online.service` posts at boot. If the last
#    boot did not shut down cleanly (a power cut, crash or hang) it says so,
#    and pings; otherwise it does not.
#  - The host goes down cleanly: the same unit posts when it is stopped at
#    shutdown, saying whether it is a reboot. Does not ping.
#
# Not covered here:
#
#  - A failed fetch, evaluation or build of `main` on the host. comin runs no
#    hook after a failed evaluation, and reports a cancelled build (preempted
#    by a newer commit) through its build hook the same way as a failed one,
#    and again for each retry. Its exporter tells them apart
#    (`comin_last_{fetch,eval,build}_failed`), so phase 3's alert rules (#27)
#    take them. CI builds the same configuration before merge, so a failure
#    there is the host's environment (disk, network), not the code.
#  - Being down. A host that is off cannot say so; the boot message reports
#    an unclean shutdown afterwards, and only a check from outside can report
#    one while it lasts (#112).
#
# The webhook URL is a secret: anyone holding it can post to the channel. It is
# never put on a command line, where any local user could read it from /proc;
# curl reads it from a config file on a pipe. Messages allow only the one role
# to be mentioned, so a log line containing `@everyone` stays text.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.notify;
  host = config.networking.hostName;

  # The first thing in each title, so the channel reads at a glance: up,
  # going down on purpose, or something wrong (which also pings).
  icon = {
    up = "🟢";
    down = "🟠";
    wrong = "🔴";
  };

  # homeserver-notify WEBHOOK_FILE ROLE_FILE ICON TITLE, with the body on stdin.
  # ROLE_FILE is `-` for a message that pings no one.
  send = pkgs.writeShellApplication {
    name = "homeserver-notify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      webhook_file=$1
      role_file=$2
      # The time in UTC (Coordinated Universal Time), after the icon: Discord
      # shows only the time of day, in the reader's own zone, and groups
      # messages under one heading.
      title="$3 [$(date -u +%Y-%m-%dT%H:%M:%SZ)] $4"
      body=$(cat)
      role=
      if [ "$role_file" != - ]; then
        role=$(< "$role_file")
        [[ $role =~ ^[0-9]+$ ]] || { echo "role id is not a number" >&2; exit 1; }
      fi
      # Discord refuses a message over 2000 characters; keep the end, where
      # the error usually is. A code fence in the body would end ours early.
      body=''${body//\`\`\`/\'\'\'}
      # And a zero-width space after each @, so `@everyone` in a log line does
      # not even look like a mention; allowed_mentions below is what stops it
      # pinging. Bytes, not \u200b (U+200B), which needs a UTF-8 locale.
      body=''${body//@/@$'\xe2\x80\x8b'}
      max=$((1900 - ''${#title}))
      if [ "''${#body}" -gt "$max" ]; then
        body="…''${body: -$max}"
      fi
      content="**$title**"
      [ -z "$role" ] || content="<@&$role> $content"
      fence=$'\x60\x60\x60'
      [ -z "$body" ] || content="$content"$'\n'"$fence"$'\n'"$body"$'\n'"$fence"
      # Retried, for the boot message above all: the network may be up before
      # DNS (Domain Name System) is. All errors, since a DNS failure is not one
      # curl retries by default, but 30 s in all: a post holds up whatever
      # waits on its sender (boot, shutdown, comin's next deployment).
      jq -n --arg content "$content" --arg role "$role" \
        '{content: $content, allowed_mentions: {parse: [], roles: ([$role] - [""])}}' |
        curl --fail --silent --show-error --max-time 10 \
          --retry 3 --retry-delay 5 --retry-all-errors --retry-max-time 30 \
          --header 'Content-Type: application/json' --data-binary @- \
          --config <(printf 'url = "%s"\n' "$(< "$webhook_file")")
    '';
  };

  roleArg = if cfg.roleFile == null then "-" else cfg.roleFile;

  deployHook = pkgs.writeShellScript "notify-comin-deployment" ''
    [ "$COMIN_STATUS" = failed ] || exit 0
    # comin keeps a hook's output to itself, logging only its exit status
    # (deployer.go in 0.14.0), so errors go to the journal from here.
    exec 2> >(${pkgs.systemd}/bin/systemd-cat --identifier notify-comin-deployment --priority err)
    printf 'commit %s: %s\n\n%s\n' "''${COMIN_GIT_SHA:0:12}" "$COMIN_GIT_MSG" "$COMIN_ERROR_MSG" |
      ${lib.getExe send} ${lib.escapeShellArg cfg.webhookFile} ${lib.escapeShellArg roleArg} \
        ${icon.wrong} ${lib.escapeShellArg "${host}: comin deployment failed"}
  '';

  # For units that run as a dynamic user: systemd hands each the files it
  # needs as credentials, readable by that unit alone.
  credentials = [
    "webhook:${cfg.webhookFile}"
  ]
  ++ lib.optional (cfg.roleFile != null) "role:${cfg.roleFile}";
  credRole = if cfg.roleFile == null then "-" else ''"$CREDENTIALS_DIRECTORY/role"'';
  hardening = {
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    ProtectHome = true;
    PrivateDevices = true;
  };
in
{
  options.homeserver.notify = {
    webhookFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File holding the Discord webhook URL, decrypted at activation (sops),
        never a store path. null turns notifications off.
      '';
    };
    roleFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File holding the id of the Discord role that failures ping. null pings
        no one.
      '';
    };
    cooldown = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = ''
        Seconds after a unit's failure is posted during which its further
        failures are counted, not posted.
      '';
    };
    sender = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = send;
      description = ''
        The program that posts: `homeserver-notify WEBHOOK_FILE ROLE_FILE
        ICON TITLE`, with the body on stdin and ROLE_FILE `-` to ping no one.
        For posters outside this module, such as the stack watcher
        (modules/containers/compose-stack.nix).
      '';
    };
    icons = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = icon;
      description = "The icons that start each title: `up`, `down` and `wrong`.";
    };
    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sshd" ];
      description = ''
        Services, by name without `.service`, whose failure is posted. Each
        must exist: naming one that does not creates an empty unit, which
        systemd refuses to load (tests/notify.py checks each is loaded).
      '';
    };
  };

  config = lib.mkIf (cfg.webhookFile != null) (
    lib.mkMerge [
      {
        assertions =
          map
            (f: {
              assertion = f == null || !lib.hasPrefix builtins.storeDir f;
              message = "homeserver.notify: ${f} is in the Nix store, which every local user can read.";
            })
            [
              cfg.webhookFile
              cfg.roleFile
            ];

        # The services the base modules run, each only where it exists.
        # Ticket-specific ones add themselves beside their unit.
        homeserver.notify.units =
          lib.optional config.services.comin.enable "comin"
          ++ lib.optional config.services.openssh.enable "sshd"
          ++ lib.optional config.nix.gc.automatic "nix-gc"
          ++ lib.optional config.services.tailscale.enable "tailscaled"
          ++ lib.optional (
            config.services.tailscale.enable && config.services.tailscale.authKeyFile != null
          ) "tailscaled-autoconnect"
          ++ lib.optional config.services.fstrim.enable "fstrim"
          ++ lib.optional config.services.logrotate.enable "logrotate";

        systemd.services = {
          "notify-failure@" = {
            description = "Post the failure of %i to Discord";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            scriptArgs = "%i";
            # systemd starts this on every failure, including each one followed by
            # an automatic restart (tests/notify.py, systemd 260), so a unit stuck
            # in a crash loop would post every few seconds. One message per unit
            # per cooldown; failures inside it are counted, and the next message
            # says how many.
            script = ''
              unit=$1
              state=$STATE_DIRECTORY/$unit
              now=$(date +%s)
              last=0
              held=0
              # A file cut short by a power cut, or unreadable, counts as none:
              # failing here would silence the unit for good.
              if [ -e "$state" ]; then
                read -r last held < "$state" || true
              fi
              [[ $last =~ ^[0-9]+$ && $held =~ ^[0-9]+$ ]] || { last=0; held=0; }
              save() {
                echo "$1 $2" > "$state.new"
                mv "$state.new" "$state"
              }
              # 0 or more: a clock set back past the last post does not hold
              # posts back until it catches up.
              if [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt ${toString cfg.cooldown} ]; then
                save "$last" $((held + 1))
                echo "posted about $unit $((now - last)) s ago; holding this one back"
                exit 0
              fi
              # In the title, which is never cut to fit, unlike the log.
              title="${host}: $unit failed"
              if [ "$held" -gt 0 ]; then
                title="$title ($held more times since the last message, not posted)"
              fi
              # The failed run only, not earlier runs or boots.
              journalctl --unit "$unit" --invocation 0 --lines 20 --no-pager --output short-iso |
                ${lib.getExe send} "$CREDENTIALS_DIRECTORY/webhook" ${credRole} ${icon.wrong} "$title"
              save "$now" 0
            '';
            path = [
              pkgs.coreutils
              pkgs.systemd
            ];
            serviceConfig = hardening // {
              Type = "oneshot";
              StateDirectory = "notify-failure";
              DynamicUser = true;
              LoadCredential = credentials;
              # The journal is readable by its group; root is not needed.
              SupplementaryGroups = [ "systemd-journal" ];
            };
          };

          # Up at boot, down at shutdown. A marker in its state directory lives
          # from start to stop, so finding it at start means the last boot never
          # stopped this unit: it ended without a clean shutdown. The marker, not
          # the journal: what the journal held in memory is lost in a power cut.
          notify-online = {
            description = "Post to Discord when the host comes up and goes down";
            wantedBy = [ "multi-user.target" ];
            # network.target too, so it is stopped before the network is.
            after = [
              "network-online.target"
              "network.target"
            ];
            wants = [ "network-online.target" ];
            # A deploy that changes this unit must not post a fake down and up.
            restartIfChanged = false;
            path = [
              pkgs.coreutils
              pkgs.systemd
            ];
            script = ''
              marker=/var/lib/notify-online/running
              if [ -e "$marker" ]; then
                unclean=1
              else
                unclean=0
              fi
              touch "$marker"
              # All of it, not the file alone: a new file's directory entry is
              # what makes it exist after a power cut. ext4 and btrfs often commit
              # it soon anyway, so the VM test passes without this too; it is here
              # for the power cut that comes first.
              sync
              kernel=$(uname -r)
              # A failed post must not fail the unit: a failed unit is not stopped
              # at shutdown, which would leave the marker and report the next boot
              # as unclean.
              if [ "$unclean" = 1 ]; then
                echo "The last boot ended without a clean shutdown (power cut, crash or hang); when it went down is not known." |
                  ${lib.getExe send} ${lib.escapeShellArg cfg.webhookFile} ${lib.escapeShellArg roleArg} ${icon.wrong} "${host} is up after an unclean shutdown, kernel $kernel" ||
                  echo "could not post the boot message" >&2
              else
                ${lib.getExe send} ${lib.escapeShellArg cfg.webhookFile} - ${icon.up} "${host} is up, kernel $kernel" < /dev/null ||
                  echo "could not post the boot message" >&2
              fi
            '';
            preStop = ''
              rm -f /var/lib/notify-online/running
              sync
              # A queued job for one of these targets: the host comes back.
              if systemctl list-jobs --no-legend reboot.target kexec.target soft-reboot.target | grep -q .; then
                what=rebooting
              else
                what="shutting down"
              fi
              ${lib.getExe send} ${lib.escapeShellArg cfg.webhookFile} - ${icon.down} "${host} is $what" < /dev/null ||
                echo "could not post the shutdown message" >&2
            '';
            # As root, reading the secrets where sops-nix put them, as comin's hook
            # does. With a dynamic user and LoadCredential=, as notify-failure@
            # has, ExecStop= could not use the credentials: $CREDENTIALS_DIRECTORY
            # was empty there, and with the path given as %d, reading the file was
            # denied (tests/notify.py, 2026-10-21).
            serviceConfig = hardening // {
              Type = "oneshot";
              RemainAfterExit = true;
              StateDirectory = "notify-online";
            };
          };
        }
        // lib.genAttrs cfg.units (_: {
          onFailure = [ "notify-failure@%n.service" ];
        });
      }

      # Only where comin.nix is imported: tests/stack-data.nix uses this module
      # without it.
      (lib.optionalAttrs (options.homeserver ? comin) {
        homeserver.comin.postDeployment = [ "${deployHook}" ];
      })
    ]
  );
}
