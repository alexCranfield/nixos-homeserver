import json

STATE = "/var/lib/tenant-runner"


def metrics():
    return run.succeed("curl -sf http://127.0.0.1:9100/metrics")


def ci(sha, *runs, raw=None):
    """Set the stub's CI runs for a commit: (status, conclusion) pairs."""
    if raw is not None:
        run.succeed(f"echo '{raw}' > /tmp/ci/{sha}.json")
        return
    body = {
        "workflow_runs": [
            {"name": "CI", "status": s, "conclusion": c, "html_url": f"https://ci.test/{sha}"}
            for s, c in runs
        ]
    }
    run.succeed(f"echo '{json.dumps(body)}' > /tmp/ci/{sha}.json")


def commit(message, passed=True):
    run.succeed(
        "cd /work && git add -A && "
        f"git -c user.name=tenant -c user.email=tenant@example.com commit -q -m '{message}' && "
        "git push -q origin main"
    )
    sha = run.succeed("git -C /work rev-parse HEAD").strip()
    if passed:
        ci(sha, ("completed", "success"))
    return sha


def posts():
    return int(run.succeed("find /tmp/webhook -name '*.json' | wc -l").strip())


start_all()
run.wait_for_unit("multi-user.target")

with subtest("first boot makes the keys, and only their public halves are readable"):
    run.wait_for_unit("tenant-runner-keys.service")
    run.succeed(f"stat -c %a {STATE}/keys | grep -x 700")
    run.succeed(f"stat -c %a {STATE}/keys/deploy_key | grep -x 600")
    run.succeed(f"stat -c %a {STATE}/keys/age.key | grep -x 600")
    run.succeed(f"grep -q '^ssh-ed25519 ' {STATE}/deploy_key.pub")
    AGE_PUB = run.succeed(f"cat {STATE}/age.pub").strip()
    assert AGE_PUB.startswith("age1"), AGE_PUB
    run.succeed(f"journalctl -u tenant-runner-keys -o cat | grep -F '{AGE_PUB}'")

with subtest("the keys survive a restart of their unit"):
    before = run.succeed(f"cat {STATE}/deploy_key.pub {STATE}/age.pub")
    run.succeed("systemctl restart tenant-runner-keys.service")
    assert run.succeed(f"cat {STATE}/deploy_key.pub {STATE}/age.pub") == before

run.wait_for_unit("docker.service")
run.wait_for_unit("webhook.service")
run.wait_for_unit("ci-stub.service")
run.succeed(f"docker load < {IMAGE}")
run.succeed(
    "git init -q --bare --initial-branch=main /srv/repo.git && "
    "git init -q --initial-branch=main /work && "
    "git -C /work remote add origin /srv/repo.git && "
    f"cp -r {FIXTURE}/. /work/ && chmod -R u+w /work && mkdir /work/secrets"
)


def encrypt(recipient):
    run.succeed(
        "printf 'FAILURE_WEBHOOK: http://127.0.0.1:%d/hook\\nGREETING: hello-from-sops\\n' "
        "> /tmp/prod.yaml" % PORT
    )
    run.succeed(
        f"cd /tmp && sops --encrypt --age {recipient} --input-type yaml --output-type yaml "
        "/tmp/prod.yaml > /work/secrets/prod.yaml"
    )


with subtest("a good commit deploys and sets the success metric"):
    encrypt(AGE_PUB)
    good = commit("good")
    run.succeed("systemctl start tenant-deploy.service")
    run.succeed(f"grep -q '^{good} ' {STATE}/deployed")
    run.wait_until_succeeds("docker exec tenant-cron-1 true", timeout=60)
    run.succeed("docker exec tenant-cron-1 printenv GREETING | grep -x hello-from-sops")
    m = metrics()
    assert "tenant_deploy_success 1" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    assert f'tenant_deploy_info{{commit="{good}"}} 1' in m, m
    assert "tenant_deploy_last_run_timestamp_seconds " in m, m
    # The decrypted secrets were the run's alone.
    run.fail("test -e /run/tenant-deploy")
    run.fail("systemctl is-failed tenant-deploy.service")

with subtest("an unchanged main is not deployed again"):
    run.succeed("systemctl start tenant-deploy.service")
    run.succeed(
        f"journalctl -u tenant-deploy.service -o cat | grep -F 'main is still {good}, already deployed'"
    )
    run.succeed("grep -x done /run/tenant-runner/stage")

with subtest("after a reboot the same commit is deployed again"):
    # As a reboot leaves it: the commit deployed, in another boot.
    run.succeed(f"sed -i 's/ .*/ an-earlier-boot/' {STATE}/deployed")
    run.succeed("systemctl start tenant-deploy.service")
    run.succeed(
        f"journalctl -u tenant-deploy.service -o cat | grep -c '^deploying {good}$' | grep -x 2"
    )
    run.succeed(f"grep -x '{good} '$(cat /proc/sys/kernel/random/boot_id) {STATE}/deployed")

with subtest("the hello job's run updates its per-job metrics, and only its own"):
    run.wait_until_succeeds(f"test -e {STATE}/job-metrics/hello.prom", timeout=60)
    run.succeed("systemctl start tenant-job-metrics.service")
    m = metrics()
    assert 'tenant_job_last_exit{job="hello"} 0' in m, m
    assert 'tenant_job_last_run_timestamp_seconds{job="hello"}' in m, m
    run.fail(f"grep tenant_deploy {STATE}/metrics/tenant_jobs.prom")
    first = run.succeed(
        f"grep tenant_job_last_run_timestamp_seconds {STATE}/metrics/tenant_jobs.prom"
    )
    run.wait_until_succeeds(
        f"systemctl start tenant-job-metrics.service && "
        f"! grep -qxF '{first.strip()}' {STATE}/metrics/tenant_jobs.prom",
        timeout=60,
    )

with subtest("a deploy stopped mid-build is a failure the tenant hears about"):
    before = run.succeed(
        f"sed -n 's/^tenant_deploy_last_run_timestamp_seconds //p' {STATE}/metrics/tenant_deploy.prom"
    ).strip()
    run.succeed("echo 'RUN sleep 300' >> /work/Dockerfile")
    slow = commit("slow")
    run.succeed("systemctl start --no-block tenant-deploy.service")
    run.wait_until_succeeds(
        "grep -x compose /run/tenant-runner/stage && "
        f"journalctl -u tenant-deploy.service -o cat | grep -F 'deploying {slow}'",
        timeout=120,
    )
    run.succeed("sleep 5; systemctl stop tenant-deploy.service")
    m = metrics()
    assert "tenant_deploy_success 0" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    after = run.succeed(
        f"sed -n 's/^tenant_deploy_last_run_timestamp_seconds //p' {STATE}/metrics/tenant_deploy.prom"
    ).strip()
    assert int(after) > int(before), (before, after)
    # A build stopped by the 30-minute timeout is the tenant's to fix: the
    # script exits 143, so the unit fails and the handler posts.
    run.wait_until_succeeds("test -e /tmp/webhook/000.json", timeout=60)
    body = json.loads(run.succeed("cat /tmp/webhook/000.json"))
    assert f"deploying {slow[:12]} failed" in body["content"], body
    run.succeed("sed -i '/RUN sleep 300/d' /work/Dockerfile")

with subtest("a broken commit fails the unit and posts to the tenant's webhook once"):
    run.succeed("echo 'RUN exit 1' >> /work/Dockerfile")
    broken = commit("broken")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("test -e /tmp/webhook/001.json", timeout=60)
    body = json.loads(run.succeed("cat /tmp/webhook/001.json"))
    assert f"deploying {broken[:12]} failed" in body["content"], body
    assert body["text"] == body["content"], body
    m = metrics()
    assert "tenant_deploy_success 0" in m, m
    # The tenant's failure, not the platform's: Alex's alert stays quiet.
    assert "tenant_deploy_platform_ok 1" in m, m
    assert f'tenant_deploy_info{{commit="{good}"}} 1' in m, m
    # The last good commit keeps running.
    run.succeed("docker exec tenant-cron-1 printenv GREETING")
    run.wait_until_succeeds(
        "systemctl show -p Result --value tenant-deploy-failed.service | grep -x success"
    )
    # Retried by the next run, failing the same way: not posted again.
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds(
        "journalctl -u tenant-deploy-failed.service -o cat | "
        f"grep -c 'already posted for {broken}' | grep -x 1",
        timeout=60,
    )
    assert posts() == 2

with subtest("negative control: with the receiver stopped, the handler's post fails"):
    run.succeed("systemctl stop webhook.service")
    run.succeed("echo '# again' >> /work/Dockerfile")
    commit("broken again")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("systemctl is-failed tenant-deploy-failed.service", timeout=60)
    run.succeed(
        "journalctl -u tenant-deploy-failed.service -o cat | grep -i 'curl.*\\(connect\\|refused\\)'"
    )
    assert posts() == 2
    run.succeed("systemctl start webhook.service")
    run.wait_for_unit("webhook.service")

with subtest("a decrypt failure is the platform's: Alex's metric, no post to the tenant"):
    run.succeed("sed -i '/RUN exit 1/d; /# again/d' /work/Dockerfile")
    other = run.succeed("age-keygen -o /tmp/other.key && age-keygen -y /tmp/other.key").strip()
    assert other.startswith("age1"), other
    encrypt(other)
    commit("secrets for someone else")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds(
        "journalctl -u tenant-deploy-failed.service -o cat | "
        "grep -F 'failed at the decrypt stage, a platform fault'",
        timeout=60,
    )
    m = metrics()
    assert "tenant_deploy_platform_ok 0" in m, m
    assert posts() == 2

with subtest("fixing the commit deploys again"):
    encrypt(AGE_PUB)
    fixed = commit("fixed")
    run.succeed("systemctl start tenant-deploy.service")
    m = metrics()
    assert "tenant_deploy_success 1" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    assert f'tenant_deploy_info{{commit="{fixed}"}} 1' in m, m

with subtest("a commit whose CI is still running waits, then deploys once it passes"):
    run.succeed("echo '# waiting' >> /work/Dockerfile")
    waiting = commit("waiting for CI", passed=False)
    run.succeed("systemctl start tenant-deploy.service")
    run.succeed(
        "journalctl -u tenant-deploy.service -o cat | "
        f"grep -F 'CI has not finished on {waiting}: deploying it once it passes'"
    )
    m = metrics()
    assert f'tenant_deploy_info{{commit="{fixed}"}} 1' in m, m
    assert "tenant_deploy_success 1" in m, m
    ci(waiting, ("completed", "success"), ("in_progress", None))
    run.succeed("systemctl start tenant-deploy.service")
    assert f'tenant_deploy_info{{commit="{fixed}"}} 1' in metrics()
    ci(waiting, ("completed", "success"), ("completed", "skipped"))
    run.succeed("systemctl start tenant-deploy.service")
    m = metrics()
    assert f'tenant_deploy_info{{commit="{waiting}"}} 1' in m, m
    assert "tenant_deploy_success 1" in m, m

with subtest("a commit whose CI failed is not deployed, and the tenant hears once"):
    run.succeed("echo '# red' >> /work/Dockerfile")
    red = commit("CI fails", passed=False)
    ci(red, ("completed", "success"), ("completed", "failure"))
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("test -e /tmp/webhook/002.json", timeout=60)
    body = json.loads(run.succeed("cat /tmp/webhook/002.json"))
    assert f"CI failed on {red}: not deployed" in body["content"], body
    m = metrics()
    assert f'tenant_deploy_info{{commit="{waiting}"}} 1' in m, m
    assert "tenant_deploy_success 0" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds(
        "journalctl -u tenant-deploy-failed.service -o cat | "
        f"grep -c 'already posted for {red}' | grep -x 1",
        timeout=60,
    )
    assert posts() == 3

with subtest("an API that can't be asked is the platform's: Alex's metric, no post"):
    run.succeed("touch /tmp/ci/down")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds(
        "journalctl -u tenant-deploy-failed.service -o cat | "
        "grep -F 'failed at the checks stage, a platform fault'",
        timeout=60,
    )
    assert "tenant_deploy_platform_ok 0" in metrics()
    assert posts() == 3
    run.succeed("rm /tmp/ci/down")

with subtest("an answer without the runs list is the platform's too"):
    ci(red, raw='{"workflow_runs": null}')
    run.fail("systemctl start tenant-deploy.service")
    run.succeed(
        "journalctl -u tenant-deploy.service -o cat | grep -F 'no workflow_runs in the answer'"
    )
    assert "tenant_deploy_platform_ok 0" in metrics()
    assert posts() == 3

with subtest("an empty answer or a redirect is the platform's, never a pass"):
    run.succeed("echo '# gate' >> /work/Dockerfile")
    gate = commit("passes, but the API does not say so")
    for marker in ["empty", "moved"]:
        run.succeed(f"touch /tmp/ci/{marker}")
        run.fail("systemctl start tenant-deploy.service")
        run.succeed(f"rm /tmp/ci/{marker}")
        m = metrics()
        assert "tenant_deploy_platform_ok 0" in m, (marker, m)
        assert f'tenant_deploy_info{{commit="{gate}"}}' not in m, (marker, m)
    assert posts() == 3
    # Once the API answers, the passing commit deploys.
    run.succeed("systemctl start tenant-deploy.service")
    waiting = gate
    assert f'tenant_deploy_info{{commit="{gate}"}} 1' in metrics()
    run.fail(f"test -e {STATE}/pending")

with subtest("a cancelled run is a failure, not a pass"):
    run.succeed("echo '# cancelled' >> /work/Dockerfile")
    cancelled = commit("cancelled", passed=False)
    ci(cancelled, ("completed", "success"), ("completed", "cancelled"))
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("test -e /tmp/webhook/003.json", timeout=60)
    body = json.loads(run.succeed("cat /tmp/webhook/003.json"))
    assert f"CI failed on {cancelled}: not deployed" in body["content"], body
    assert "CI: cancelled" in body["content"], body
    assert f'tenant_deploy_info{{commit="{waiting}"}} 1' in metrics()

with subtest("a commit whose CI never runs fails after 6 hours, and the tenant hears"):
    run.succeed("echo '# skip ci' >> /work/Dockerfile")
    skipped = commit("[skip ci]", passed=False)
    run.succeed("systemctl start tenant-deploy.service")
    run.succeed(f"grep -q '^{skipped} ' {STATE}/pending")
    # As if the first wait were 6 hours and a minute ago.
    run.succeed(f"echo {skipped} $(($(date +%s) - 21660)) > {STATE}/pending")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("test -e /tmp/webhook/004.json", timeout=60)
    body = json.loads(run.succeed("cat /tmp/webhook/004.json"))
    assert f"CI has not passed on {skipped} in 6 hours" in body["content"], body
    assert f'tenant_deploy_info{{commit="{waiting}"}} 1' in metrics()

with subtest("the runner asked only for its repo's runs from pushes to main"):
    run.fail("cat /tmp/ci/wrong-question")

with subtest("the token reaches the API from a file, not curl's arguments"):
    # The stub refuses a request without it, so the deploys above sent it;
    # it looked at every command line while each request was open.
    run.succeed("test -e /tmp/ci/asked")
    run.fail("cat /tmp/ci/leaked")


def restarts(name):
    """The container's restart count, from the runner's metrics."""
    run.succeed("systemctl start tenant-job-metrics.service")
    m = metrics()
    prefix = f'tenant_container_restarts_total{{container="{name}"}} '
    lines = [line for line in m.splitlines() if line.startswith(prefix)]
    assert len(lines) == 1, m
    return int(lines[0].removeprefix(prefix))


with subtest("a stack that crashes once it is up fails the deploy; the tenant hears once"):
    # Up long enough for `compose up --wait` to pass it (#210), then down.
    run.succeed("cp /work/Dockerfile /tmp/Dockerfile.good")
    run.succeed(
        "echo 'CMD [\"sh\", \"-c\", \"echo crashing; sleep 8; exit 1\"]' >> /work/Dockerfile"
    )
    crash = commit("crashes 8 s after it starts")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("test -e /tmp/webhook/005.json", timeout=60)
    content = json.loads(run.succeed("cat /tmp/webhook/005.json"))["content"]
    assert f"deploying {crash[:12]} failed" in content, content
    assert "the stack did not stay up:" in content, content
    assert "tenant-cron-1 restarted" in content or "tenant-cron-1 is restarting" in content, content
    # The container's own log, for the tenant to read.
    assert "tenant-cron-1: crashing" in content, content
    m = metrics()
    assert "tenant_deploy_success 0" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    run.fail(f"grep -q '^{crash} ' {STATE}/deployed")

with subtest("the crash loop shows in the container metrics, rising"):
    first = restarts("tenant-cron-1")
    assert first >= 1, first
    assert 'tenant_container_running{container="tenant-cron-1"}' in metrics()
    run.wait_until_succeeds(
        "systemctl start tenant-job-metrics.service && "
        "curl -sf http://127.0.0.1:9100/metrics | "
        "awk -v p='tenant_container_restarts_total{container=\"tenant-cron-1\"}' "
        f"'$1 == p {{ n = $2 }} END {{ exit !(n > {first}) }}'",
        timeout=120,
    )

with subtest("retried, it fails the same way and is not posted again"):
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds(
        "journalctl -u tenant-deploy-failed.service -o cat | "
        f"grep -c 'already posted for {crash}' | grep -x 1",
        timeout=60,
    )
    assert posts() == 6

with subtest("negative control: a stack that stays up deploys, after the same wait"):
    run.succeed("cp /tmp/Dockerfile.good /work/Dockerfile")
    steady = commit("stays up")
    # Earlier deploys waited too, so count this run's line alone.
    waits = (
        "journalctl -u tenant-deploy.service -o cat | "
        "grep -cx 'waiting 20s for the stack to settle' || true"
    )
    before = int(run.succeed(waits))
    run.succeed("systemctl start tenant-deploy.service")
    assert int(run.succeed(waits)) == before + 1
    m = metrics()
    assert f'tenant_deploy_info{{commit="{steady}"}} 1' in m, m
    assert "tenant_deploy_success 1" in m, m
    # A new container, so its count started again.
    assert restarts("tenant-cron-1") == 0
    assert 'tenant_container_running{container="tenant-cron-1"} 1' in metrics()
    assert posts() == 6


def docker_up():
    """The runner's tenant_docker_up, or None if it isn't there."""
    for line in metrics().splitlines():
        if line.startswith("tenant_docker_up "):
            return line.split()[1]
    return None


with subtest("with Docker answering, its gauge is 1"):
    run.succeed("systemctl start tenant-job-metrics.service")
    assert docker_up() == "1", metrics()

with subtest("Docker down is the platform's: the gauge drops, no post to the tenant"):
    # Both, or the next `docker` command would start it again from the socket.
    run.succeed("systemctl stop docker.socket docker.service")
    # Left to the timer, which runs every minute: within 2 minutes.
    run.wait_until_succeeds(
        "curl -sf http://127.0.0.1:9100/metrics | grep -x 'tenant_docker_up 0'", timeout=120
    )
    m = metrics()
    # The containers' file is gone rather than stale.
    assert "tenant_container_running" not in m, m
    run.succeed("echo '# docker down' >> /work/Dockerfile")
    down = commit("deployed while Docker is down")
    run.fail("systemctl start tenant-deploy.service")
    run.succeed("journalctl -u tenant-deploy.service -o cat | grep -Fx 'Docker does not answer: not deployed'")
    run.wait_until_succeeds(
        "journalctl -u tenant-deploy-failed.service -o cat | "
        "grep -F 'failed at the docker stage, a platform fault'",
        timeout=60,
    )
    m = metrics()
    assert "tenant_deploy_platform_ok 0" in m, m
    assert f'tenant_deploy_info{{commit="{down}"}}' not in m, m
    run.fail("systemctl is-active docker.service")
    assert posts() == 6

with subtest("negative control: Docker back, the gauge is 1 and the commit deploys"):
    run.succeed("systemctl start docker.socket docker.service")
    run.succeed("systemctl start tenant-job-metrics.service")
    assert docker_up() == "1", metrics()
    run.succeed("systemctl start tenant-deploy.service")
    m = metrics()
    assert f'tenant_deploy_info{{commit="{down}"}} 1' in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    assert 'tenant_container_running{container="tenant-cron-1"} 1' in m, m
    assert posts() == 6
