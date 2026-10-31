# The nuc's private DNS data, ticket #164 (modules/dns, modules/observability).
#
# Two values must stay out of the public repository: the local names that
# only Alex's devices should resolve, and the NAS's LAN address, which the
# NAS's DNS probes need. Both live in secrets/dns.yaml. sops-nix decrypts them
# at activation, so neither reaches the Nix store.
{ config, ... }:
{
  sops.secrets.dns-private-hosts = {
    sopsFile = ../../secrets/dns.yaml;
    key = "private-hosts";
    # Blocky reads it as a systemd credential (LoadCredential, as root), and
    # only at start, so a changed secret needs a restart.
    restartUnits = [ "blocky.service" ];
  };
  homeserver.dns.privateHostsFile = config.sops.secrets.dns-private-hosts.path;

  sops.secrets.nas-address.sopsFile = ../../secrets/dns.yaml;

  # The Prometheus file_sd file naming the NAS's DNS server, with the label
  # the probe jobs and alerts expect (modules/observability/probes.nix).
  # Prometheus watches the file and reloads it on change, so no restart.
  sops.templates."dns-secondary.json" = {
    owner = "prometheus";
    content = builtins.toJSON [
      {
        targets = [ config.sops.placeholder.nas-address ];
        labels.server = "nas";
      }
    ];
  };
  homeserver.alerting.dnsServers.secondaryTargetsFile =
    config.sops.templates."dns-secondary.json".path;
}
