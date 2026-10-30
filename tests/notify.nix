# Test for ticket 2.5 (#20): failures reach the webhook, and nothing else does.
#
# One VM (virtual machine) runs the real host configuration, with the webhook
# pointed at a receiver inside the VM, since the build sandbox has no internet.
# The receiver stores each request body in the driver's shared directory, where
# the script reads them back from the host.
#
# What it proves: every unit the host watches loads with the handler attached;
# a failing unit posts its name and the end of its log, cut to Discord's limit,
# pinging the role and no one else; comin's deployment hook posts a failed
# deployment and stays quiet after a successful one; the host posts when it
# comes up and goes down, and tells a clean reboot from a power cut; the URL
# never reaches the journal. It
# does not prove Discord accepts the message: that is checked once on the nuc
# (docs/runbooks/notifications.md).
{
  pkgs,
  inputs,
  lib,
}:
let
  port = 8099;
  secret = "token-that-must-not-be-logged";
  url = "http://127.0.0.1:${toString port}/api/webhooks/1/${secret}";
  role = "123456789012345678";
  receiver = pkgs.writers.writePython3 "webhook-receiver" { } ''
    import http.server
    import pathlib

    # The test driver's shared directory, on the host: what the receiver
    # stores survives the VM's power cut, which only the marker under test
    # has to. (Stored on the VM's disk, a received message came back empty
    # after the crash even with os.fsync.)
    out = pathlib.Path("/tmp/shared/webhook")
    out.mkdir(exist_ok=True)


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            n = len(list(out.glob("*.json")))
            # Written whole under a temporary name, so a reader never sees a
            # partial message.
            (out / f"{n:03}.tmp").write_bytes(body)
            (out / f"{n:03}.tmp").rename(out / f"{n:03}.json")
            self.send_response(204)
            self.end_headers()

        # Discord's side would log the path, which holds the token; the
        # receiver stands in for Discord, so the journal check covers only
        # the host's own units.
        def log_message(self, format, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "notify";
  node.specialArgs = { inherit inputs; };
  # As in base-ssh.nix: the host sets `nixpkgs.hostPlatform`, and every
  # machine shares the test's `pkgs`.
  node.pkgsReadOnly = false;
  defaults.nixpkgs.pkgs = pkgs;

  nodes.nuc = {
    imports = [
      ../hosts/nuc
      (import ./grafana-password.nix { inherit pkgs; }).module
    ];
    # The host's stacks pull images, and the build sandbox has no internet;
    # tests/compose-stack.nix covers them.
    homeserver.stacks = lib.mkForce { };
    # The LAN's DNS server would bind the real nuc's address, which this VM
    # doesn't have; tests/dns.nix covers it.
    homeserver.dns.listenAddresses = lib.mkForce [ ];
    # As in base-ssh.nix: the sops secrets cannot be decrypted here. Copied
    # out of the store at boot instead, as sops-nix would put them, since a
    # store path fails the assertion in modules/base/notify.nix.
    services.tailscale.authKeyFile = lib.mkForce null;
    homeserver.notify.webhookFile = lib.mkForce "/run/notify-test/webhook";
    homeserver.notify.roleFile = lib.mkForce "/run/notify-test/role";
    # Public messages (#161) have their own test, tests/announce.nix.
    homeserver.announce.webhookFile = lib.mkForce null;
    systemd.tmpfiles.rules = [
      "C /run/notify-test/webhook 0400 root root - ${pkgs.writeText "webhook" url}"
      "C /run/notify-test/role 0400 root root - ${pkgs.writeText "role" role}"
    ];
    # So the boot message has somewhere to go.
    systemd.services.notify-online.after = [ "webhook-receiver.service" ];

    systemd.services.webhook-receiver = {
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = "/tmp/shared";
      serviceConfig.ExecStart = receiver;
    };

    # Fails on demand, with more log than one message holds. The last line
    # carries a mention and a code fence, which must arrive as text.
    # Short, so the test can see a held-back failure reported.
    homeserver.notify.cooldown = 30;
    homeserver.notify.units = [
      "notify-probe"
      "notify-flappy"
    ];
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

    # Fails and is restarted, three times in 60 s before systemd gives up:
    # does each failure post, or only the last?
    systemd.services.notify-flappy = {
      script = "echo flapping; exit 1";
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 1;
      };
      unitConfig = {
        StartLimitIntervalSec = 60;
        StartLimitBurst = 3;
      };
    };

    # A deploy that changes notify-online, which must not post. In [Service]:
    # switch-to-configuration restarts nothing for a new Description (or
    # OnFailure=, among others), so that would pass whatever restartIfChanged
    # said.
    specialisation.changed.configuration = {
      systemd.services.notify-online.environment.DEPLOYED = "changed";
    };
    # As in reboot-window.nix: sops-nix cannot decrypt here, and its failure
    # would fail the switch.
    system.activationScripts.setupSecrets = lib.mkForce "";
  };

  testScript =
    { nodes, ... }:
    ''
      PORT = ${toString port}
      SECRET = ${builtins.toJSON secret}
      ROLE = ${builtins.toJSON role}
      UNITS = ${builtins.toJSON nodes.nuc.homeserver.notify.units}
      DEPLOY_HOOK = ${builtins.toJSON "${nodes.nuc.services.comin.postDeploymentCommand}"}
    ''
    + builtins.readFile ./notify.py;
}
