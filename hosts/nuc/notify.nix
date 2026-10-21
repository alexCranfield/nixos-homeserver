# Where the nuc's failure notifications go, ticket 2.5 (#20): a Discord
# webhook (modules/base/notify.nix, docs/runbooks/notifications.md).
#
# The URL is the only credential: whoever holds it can post to the channel,
# though not read it. sops-nix decrypts it into /run/secrets at activation,
# readable by root alone.
{ config, ... }:
{
  sops.secrets.discord-webhook.sopsFile = ../../secrets/notify.yaml;
  homeserver.notify.webhookFile = config.sops.secrets.discord-webhook.path;
}
