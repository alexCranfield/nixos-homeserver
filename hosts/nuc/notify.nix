# Where the nuc's notifications go, ticket 2.5 (#20): a Discord webhook, and
# the role that failures ping (modules/base/notify.nix,
# docs/runbooks/notifications.md).
#
# The URL is the only credential: whoever holds it can post to the channel,
# though not read it. The role id is not secret, but kept beside it so the
# public repo carries no id of Alex's Discord server. sops-nix decrypts both
# into /run/secrets at activation, readable by root alone.
{ config, ... }:
{
  sops.secrets.discord-webhook.sopsFile = ../../secrets/notify.yaml;
  sops.secrets.discord-role.sopsFile = ../../secrets/notify.yaml;
  homeserver.notify.webhookFile = config.sops.secrets.discord-webhook.path;
  homeserver.notify.roleFile = config.sops.secrets.discord-role.path;
}
