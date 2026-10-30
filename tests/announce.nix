# Test for ticket #161: public status messages reach the public webhook and
# the game's chat, and nothing private does.
#
# One VM (virtual machine) runs the real host configuration. Both webhooks
# point at a receiver inside the VM, as in tests/notify.nix; it files each
# request under `private` or `public` by its path. The Minecraft server is a
# stand-in container whose `rcon-cli` records the JSON (JavaScript Object
# Notation) each `tellraw` gets: the build sandbox has no internet to fetch a
# real one, and a real server's handling of that JSON was checked by hand
# (pull request for #161).
#
# What it proves: comin's build hook announces a new system with its pull
# request or commit, and stays quiet for the one already running; its
# deployment hook announces the outcome, a failure in Discord only; the
# reboot window warns only when it is about to reboot, then reboots; the
# host announces it is back up; `nuc-announce` posts text as text, pinging
# no one; a stopped server is skipped without error; neither URL reaches the
# journal.
{
  pkgs,
  inputs,
  lib,
}:
let
  port = 8099;
  privateSecret = "private-token-not-to-log";
  publicSecret = "public-token-not-to-log";
  url = id: secret: "http://127.0.0.1:${toString port}/api/webhooks/${id}/${secret}";
  role = "123456789012345678";
  receiver = pkgs.writers.writePython3 "webhook-receiver" { } ''
    import http.server
    import pathlib

    # The driver's shared directory: what was received before a reboot is
    # read after it.
    out = pathlib.Path("/tmp/shared/webhook")


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            kind = "public" if "/2/" in self.path else "private"
            d = out / kind
            d.mkdir(parents=True, exist_ok=True)
            body = self.rfile.read(int(self.headers["Content-Length"]))
            n = len(list(d.glob("*.json")))
            (d / f"{n:03}.tmp").write_bytes(body)
            (d / f"{n:03}.tmp").rename(d / f"{n:03}.json")
            self.send_response(204)
            self.end_headers()

        def log_message(self, format, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';

  # The stand-in server: `rcon-cli tellraw @a JSON` appends the JSON to a
  # file on the host, one line each, and replies nothing, as a real server
  # does with a player on.
  rconCli = pkgs.writeTextFile {
    name = "rcon-cli";
    destination = "/bin/rcon-cli";
    executable = true;
    text = ''
      #!/bin/sh
      [ "$1" = tellraw ] && [ "$2" = @a ] && printf '%s\n' "$3" >> /log/tellraw
    '';
  };
  image = pkgs.dockerTools.buildImage {
    name = "fakemc";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "fakemc-root";
      paths = [
        pkgs.busybox
        rconCli
      ];
    };
    config.Cmd = [
      "sleep"
      "1000000"
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "announce";
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
    # The host's stacks pull images, and the build sandbox has no internet.
    homeserver.stacks = lib.mkForce { };
    # The LAN's DNS server would bind the real nuc's address, which this VM
    # doesn't have; tests/dns.nix covers it.
    homeserver.dns.listenAddresses = lib.mkForce [ ];
    # As in tests/notify.nix: no sops secret can be decrypted here, so the
    # files are copied out of the store at boot, where sops-nix would put
    # them.
    services.tailscale.authKeyFile = lib.mkForce null;
    system.activationScripts.setupSecrets = lib.mkForce "";
    homeserver.notify.webhookFile = lib.mkForce "/run/announce-test/private";
    homeserver.notify.roleFile = lib.mkForce "/run/announce-test/role";
    homeserver.announce.webhookFile = lib.mkForce "/run/announce-test/public";
    systemd.tmpfiles.rules = [
      "C /run/announce-test/private 0400 root root - ${pkgs.writeText "private" (url "1" privateSecret)}"
      "C /run/announce-test/public 0400 root root - ${pkgs.writeText "public" (url "2" publicSecret)}"
      "C /run/announce-test/role 0400 root root - ${pkgs.writeText "role" role}"
    ];
    systemd.services.webhook-receiver = {
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = "/tmp/shared";
      serviceConfig.ExecStart = receiver;
    };
    systemd.services.notify-online.after = [ "webhook-receiver.service" ];
    systemd.services.announce-online.after = [ "webhook-receiver.service" ];

    homeserver.announce.minecraftContainers = [ "fakemc" ];
    # Ten seconds, not five minutes; the reminder then comes at once.
    homeserver.announce.rebootWarning = 10;

    systemd.services.fakemc = {
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      path = [ pkgs.docker ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      script = ''
        docker load < ${image}
        mkdir -p /var/lib/fakemc
        docker rm -f fakemc || true
        docker run -d --name fakemc -v /var/lib/fakemc:/log fakemc:test
      '';
    };
  };

  testScript =
    { nodes, ... }:
    ''
      PRIVATE_SECRET = ${builtins.toJSON privateSecret}
      PUBLIC_SECRET = ${builtins.toJSON publicSecret}
      ROLE = ${builtins.toJSON role}
      BUILD_HOOK = ${builtins.toJSON "${nodes.nuc.services.comin.postBuildCommand}"}
      DEPLOY_HOOK = ${builtins.toJSON "${nodes.nuc.services.comin.postDeploymentCommand}"}
      CALENDAR = ${builtins.toJSON nodes.nuc.homeserver.rebootWindow.calendar}
      REPO = ${builtins.toJSON nodes.nuc.homeserver.announce.repoUrl}
    ''
    + builtins.readFile ./announce.py;
}
