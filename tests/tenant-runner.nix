# Test for ticket 6.9 (#199): the tenant runner (modules/tenants/runner.nix)
# deploys its repo's `main`, gives the stack its decrypted secrets and its
# jobs' metrics, and tells the tenant when a commit fails to deploy, but not
# when the platform fails; ADR (Architecture Decision Record) 0013.
#
# CI (continuous integration) cannot boot the microVM itself (it would be a
# VM inside the test VM), so the runner's guest module runs on a plain test
# node, `run`. In place of GitHub, a bare repository in the node at a
# `file://` URL; in place of a registry, an image built by Nix and loaded,
# which the fixture's Dockerfile builds on. In place of the tenant's webhook,
# a receiver on the node that keeps each post. The node's own deploy timer is
# off: the test starts each deploy.
{
  pkgs,
  lib,
}:
let
  port = 8099;

  # busybox, as in tests/compose-stack.nix.
  image = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "probe-root";
      paths = [ pkgs.busybox ];
    };
  };

  # The tenant's repo, as tenant-run sees it. The job writes its metrics as
  # the template's `run-job` will, and one line it may not: a deploy series.
  fixture = pkgs.runCommand "tenant-fixture" { } ''
    mkdir $out
    cat >$out/compose.yml <<'EOF'
    services:
      cron:
        build: .
        env_file: ''${TENANT_SECRETS}
        volumes:
          - ''${TENANT_JOB_METRICS}:/metrics
        restart: unless-stopped
    EOF
    cat >$out/Dockerfile <<'EOF'
    FROM probe:test
    COPY hello /hello
    CMD ["sh", "/hello"]
    EOF
    cat >$out/hello <<'EOF'
    while :; do
      {
        echo 'tenant_job_last_exit{job="hello"} 0'
        echo "tenant_job_last_run_timestamp_seconds{job=\"hello\"} $(date +%s)"
        echo 'tenant_deploy_success 1'
      } >/metrics/hello.prom.tmp
      mv /metrics/hello.prom.tmp /metrics/hello.prom
      sleep 10
    done
    EOF
  '';

  receiver = pkgs.writers.writePython3 "webhook-receiver" { } ''
    import http.server
    import pathlib

    out = pathlib.Path("/tmp/webhook")
    out.mkdir(exist_ok=True)


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            n = len(list(out.glob("*.json")))
            (out / f"{n:03}.tmp").write_bytes(body)
            (out / f"{n:03}.tmp").rename(out / f"{n:03}.json")
            self.send_response(204)
            self.end_headers()


    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "tenant-runner";

  nodes.run = {
    imports = [ ../modules/tenants/runner.nix ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;

    homeserver.tenantRunner.repoUrlFile = "/etc/tenant-repo-url";
    environment.etc."tenant-repo-url".text = "file:///srv/repo.git\n";
    systemd.timers.tenant-deploy.wantedBy = lib.mkForce [ ];

    systemd.services.webhook = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = receiver;
    };

    environment.systemPackages = [
      pkgs.age
      pkgs.curl
    ];
  };

  testScript = ''
    IMAGE = "${image}"
    FIXTURE = "${fixture}"
    PORT = ${toString port}
  ''
  + builtins.readFile ./tenant-runner.py;
}
