# Failure notifications to Discord, ticket 2.5 (#20).
#
# Two sources, one sender:
#
#  - A unit in `homeserver.notify.units` that fails starts
#    `notify-failure@<unit>.service` (systemd's OnFailure=), which posts the
#    unit's name and its last 20 journal lines.
#  - comin runs `postDeploymentCommand` after every deployment; a failed one
#    posts the commit and comin's error. comin itself keeps running when a
#    deployment fails, so OnFailure= on comin would not see it.
#
# Not covered here: a failed fetch, evaluation or build of `main` on the host.
# comin runs no hook after a failed evaluation, and reports a cancelled build
# (preempted by a newer commit) through its build hook the same way as a failed
# one, and again for each retry. Its exporter tells them apart
# (`comin_last_{fetch,eval,build}_failed`), so phase 3's alert rules (#27) take
# them. CI builds the same configuration before merge, so a failure there is
# the host's environment (disk, network), not the code.
#
# The webhook URL is a secret: anyone holding it can post to the channel. It is
# never put on a command line, where any local user could read it from /proc;
# curl reads it from a config file on a pipe. Messages are sent with mentions
# disabled, so a log line containing `@everyone` stays text.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeserver.notify;

  # homeserver-notify WEBHOOK_FILE TITLE, with the body on stdin.
  send = pkgs.writeShellApplication {
    name = "homeserver-notify";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      webhook_file=$1
      title=$2
      body=$(cat)
      # Discord refuses a message over 2000 characters; keep the end, where
      # the error usually is. A code fence in the body would end ours early.
      body=''${body//\`\`\`/\'\'\'}
      max=$((1900 - ''${#title}))
      if [ "''${#body}" -gt "$max" ]; then
        body="…''${body: -$max}"
      fi
      content=$(printf '**%s**\n```\n%s\n```' "$title" "$body")
      jq -n --arg content "$content" \
        '{content: $content, allowed_mentions: {parse: []}}' |
        curl --fail --silent --show-error --max-time 10 --retry 2 \
          --header 'Content-Type: application/json' --data-binary @- \
          --config <(printf 'url = "%s"\n' "$(< "$webhook_file")")
    '';
  };

  host = config.networking.hostName;

  deployHook = pkgs.writeShellScript "notify-comin-deployment" ''
    [ "$COMIN_STATUS" = failed ] || exit 0
    printf 'commit %s: %s\n\n%s\n' "''${COMIN_GIT_SHA:0:12}" "$COMIN_GIT_MSG" "$COMIN_ERROR_MSG" |
      ${lib.getExe send} ${lib.escapeShellArg cfg.webhookFile} ${lib.escapeShellArg "${host}: comin deployment failed"}
  '';
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

  config = lib.mkIf (cfg.webhookFile != null) {
    assertions = [
      {
        assertion = !lib.hasPrefix builtins.storeDir cfg.webhookFile;
        message = "homeserver.notify.webhookFile must not be in the Nix store, which every local user can read.";
      }
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
        script = ''
          journalctl --unit "$1" --lines 20 --no-pager --output short-iso |
            ${lib.getExe send} "$CREDENTIALS_DIRECTORY/webhook" "${host}: $1 failed"
        '';
        path = [ pkgs.systemd ];
        serviceConfig = {
          Type = "oneshot";
          # Root is not needed: the journal is readable by its group, and the
          # URL is handed over by systemd, readable only by this unit.
          DynamicUser = true;
          SupplementaryGroups = [ "systemd-journal" ];
          LoadCredential = [ "webhook:${cfg.webhookFile}" ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          ProtectHome = true;
          PrivateDevices = true;
        };
      };
    }
    // lib.genAttrs cfg.units (_: {
      onFailure = [ "notify-failure@%n.service" ];
    });

    services.comin.postDeploymentCommand = deployHook;
  };
}
