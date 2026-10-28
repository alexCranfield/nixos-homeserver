# The password of Grafana's admin user, ticket 3.4 (#25,
# modules/observability, docs/runbooks/observability.md).
#
# sops-nix decrypts it into /run/secrets at activation, owned by `grafana` so
# Grafana can read it through its file provider. Grafana itself reads it only
# when it first creates its database, so `grafana-admin-password.service`
# sets it again on every start, and sops-nix reruns that unit when the secret
# changes.
{ config, ... }:
{
  sops.secrets.grafana-admin-password = {
    sopsFile = ../../secrets/observability.yaml;
    owner = "grafana";
    restartUnits = [ "grafana-admin-password.service" ];
  };
  homeserver.observability.grafanaAdminPasswordFile = config.sops.secrets.grafana-admin-password.path;
}
