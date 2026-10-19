# The nuc joins the tailnet by itself, ticket 1.7 (#14).
#
# The auth key is single use, pre-approved, and tagged `tag:server`, so the nuc
# joins as a device of the tailnet rather than of Alex's account, and its key
# never expires (docs/runbooks/tailscale.md). sops-nix decrypts it into
# /run/secrets at activation, before tailscaled-autoconnect runs; tailscaled
# keeps its own login in /var/lib/tailscale afterwards, so the spent key is
# only read again if that state is lost, and a reinstall needs a new one.
#
# nixpkgs' autoconnect passes the key on the command line
# (`tailscale up --auth-key "$(cat …)"`), so for that moment any local user
# could read it from /proc. Accepted: the nuc has one user, and the key is
# single use and spent by the same command.
{ config, ... }:
{
  sops.secrets.tailscale-authkey.sopsFile = ../../secrets/tailscale.yaml;
  services.tailscale.authKeyFile = config.sops.secrets.tailscale-authkey.path;
}
