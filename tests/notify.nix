# Test for ticket 2.5 (#20): failures reach the webhook, and nothing else does.
#
# One VM (virtual machine) runs the real host configuration, with the webhook
# pointed at a receiver inside the VM, since the build sandbox has no internet.
# The receiver stores each request body; the script reads them back.
#
# What it proves: every unit the host watches loads with the handler attached;
# a failing unit posts its name and the end of its log, cut to Discord's limit,
# with mentions disabled; comin's deployment hook posts a failed deployment and
# stays quiet after a successful one; the URL never reaches the journal. It
# does not prove Discord accepts the message: that is checked once on the nuc
# (docs/runbooks/notifications.md).
{
  pkgs,
  inputs,
  lib,
}:
let
  port = 8099;
  receiver = pkgs.writers.writePython3 "webhook-receiver" { } ''
    import http.server
    import pathlib

    out = pathlib.Path("/var/lib/webhook-receiver")


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            n = len(list(out.iterdir()))
            (out / f"{n:03}.json").write_bytes(body)
            self.send_response(204)
            self.end_headers()


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "notify";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`.
  node.pkgsReadOnly = false;

  nodes.nuc = {
    imports = [ ../hosts/nuc ];
    # As in base-ssh.nix: the sops secrets cannot be decrypted here. The test
    # writes its own URL at run time; a store path would fail the assertion
    # in modules/base/notify.nix.
    services.tailscale.authKeyFile = lib.mkForce null;
    homeserver.notify.webhookFile = lib.mkForce "/run/notify-test/webhook";

    systemd.services.webhook-receiver = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = receiver;
        StateDirectory = "webhook-receiver";
      };
    };

    # Fails on demand, with more log than one message holds. The last line
    # carries a mention and a code fence, which must arrive as text.
    homeserver.notify.units = [ "notify-probe" ];
    systemd.services.notify-probe = {
      serviceConfig.Type = "oneshot";
      script = ''
        for i in $(seq 1 30); do
          printf 'line %02d %s\n' "$i" "$(printf 'x%.0s' $(seq 1 150))"
        done
        echo 'probe end @everyone ``` fence'
        exit 1
      '';
    };
  };

  testScript =
    { nodes, ... }:
    ''
      PORT = ${toString port}
      UNITS = ${builtins.toJSON nodes.nuc.homeserver.notify.units}
      DEPLOY_HOOK = ${builtins.toJSON "${nodes.nuc.services.comin.postDeploymentCommand}"}
    ''
    + builtins.readFile ./notify.py;
}
