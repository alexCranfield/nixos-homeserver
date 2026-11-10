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
# a receiver on the node that keeps each post. In place of GitHub's Actions
# API, a stub answering each commit's CI runs from /tmp/ci/<commit>.json,
# which the test writes, refusing any request without the test's token, and
# noting any process whose command line holds the token. The node's own
# deploy timer is off: the test starts each deploy.
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
    # As the template's image does: the job is not root, so it reads its
    # code only if the checkout left the files readable.
    USER 10001
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
  ciPort = 8098;
  ciStub = pkgs.writers.writePython3 "ci-stub" { } ''
    import http.server
    import pathlib
    import urllib.parse

    runs = pathlib.Path("/tmp/ci")
    runs.mkdir(exist_ok=True)


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            # While the deploy's curl waits for this answer, no process may
            # carry the token in its command line, where `ps` shows it.
            for cmdline in pathlib.Path("/proc").glob("[0-9]*/cmdline"):
                try:
                    if b"test-token" in cmdline.read_bytes():
                        (runs / "leaked").write_text(str(cmdline))
                except OSError:
                    pass
            (runs / "asked").touch()
            if self.headers.get("Authorization") != "Bearer test-token":
                self.send_response(401)
                self.end_headers()
                return
            if (runs / "down").exists():
                self.send_response(500)
                self.end_headers()
                return
            if (runs / "moved").exists():
                self.send_response(301)
                self.send_header("Location", "/repos/test/renamed/actions/runs")
                self.end_headers()
                return
            if (runs / "empty").exists():
                self.send_response(200)
                self.end_headers()
                return
            # Only the question the runner must ask: this repo's runs of
            # one commit, from pushes to main.
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if (
                url.path != "/repos/test/runner/actions/runs"
                or query.get("event") != ["push"]
                or query.get("branch") != ["main"]
            ):
                (runs / "wrong-question").write_text(self.path)
                self.send_response(404)
                self.end_headers()
                return
            sha = query["head_sha"][0]
            found = runs / f"{sha}.json"
            none = b'{"workflow_runs": []}'
            body = found.read_bytes() if found.exists() else none
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)


    http.server.HTTPServer(("127.0.0.1", ${toString ciPort}), Handler).serve_forever()
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
    homeserver.tenantRunner.ciTokenFile = "/etc/tenant-ci-token";
    environment.etc."tenant-ci-token".text = "test-token\n";
    homeserver.tenantRunner.ciApi = "http://127.0.0.1:${toString ciPort}";
    homeserver.tenantRunner.ciRepo = "test/runner";
    # Shorter than production's 30 s, which would add up over the test's
    # many deploys; longer than the crashing fixture below takes to crash.
    homeserver.tenantRunner.settleSeconds = 20;
    systemd.services.ci-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = ciStub;
    };
    systemd.timers.tenant-deploy.wantedBy = lib.mkForce [ ];
    # The test starts the deploy back to back, many times failing on purpose,
    # and each failure starts the handler; under KVM that is more than
    # systemd's default 5 starts in 10 s for either unit.
    systemd.services.tenant-deploy.startLimitIntervalSec = 0;
    systemd.services.tenant-deploy-failed.startLimitIntervalSec = 0;

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
