# For a VM (virtual machine) test of the host configuration that does not
# test notifications: the webhook and the role become plain files made at
# boot, as in tests/notify.nix, and the webhook points at a receiver in the VM
# that accepts every post and keeps nothing.
#
# Without it the sops paths of hosts/nuc/notify.nix are missing in such a test
# (it cannot decrypt), and every unit that loads them as credentials fails to
# start: the alert relay restarted every 5 seconds and loaded the emulated VM
# enough to push Grafana's start past its password unit's time limit
# (tests/observability.nix, ticket #27). A refused address instead of the
# receiver would make each post retry for 30 seconds, at every boot and
# shutdown.
{ pkgs, lib, ... }:
let
  port = 8098;
  receiver = pkgs.writers.writePython3 "notify-sink" { } ''
    import http.server


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(204)
            self.end_headers()

        # The path holds the stand-in token; nothing to log.
        def log_message(self, format, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';
in
{
  # Plain files copied out of the store at boot: a store path fails the
  # assertion in modules/base/notify.nix.
  homeserver.notify.webhookFile = lib.mkForce "/run/notify-sink/webhook";
  homeserver.notify.roleFile = lib.mkForce "/run/notify-sink/role";
  systemd.tmpfiles.rules = [
    "C /run/notify-sink/webhook 0400 root root - ${pkgs.writeText "webhook" "http://127.0.0.1:${toString port}/api/webhooks/1/sink"}"
    "C /run/notify-sink/role 0400 root root - ${pkgs.writeText "role" "123456789012345678"}"
  ];
  systemd.services.notify-sink = {
    wantedBy = [ "multi-user.target" ];
    before = [ "notify-online.service" ];
    serviceConfig.ExecStart = receiver;
  };
}
