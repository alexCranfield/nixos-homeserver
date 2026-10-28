# Grafana's admin password for the VM (virtual machine) tests of the host,
# ticket 3.4 (#25). No sops secret can be decrypted in a test, so the password
# comes from the store instead, copied at boot to where the option points.
# Without it Grafana fails to start, and so does any configuration switch a
# test makes.
{ pkgs }:
rec {
  password = "test-grafana-password";
  module = {
    homeserver.observability.grafanaAdminPasswordFile = pkgs.lib.mkForce "/run/grafana-test/password";
    systemd.tmpfiles.rules = [
      "d /run/grafana-test 0750 root grafana -"
      "C /run/grafana-test/password 0440 root grafana - ${pkgs.writeText "grafana-password" password}"
    ];
  };
}
