import json

STATE = "/var/lib/tenant-runner"


def metrics():
    return run.succeed("curl -sf http://127.0.0.1:9100/metrics")


def commit(message):
    run.succeed(
        "cd /work && git add -A && "
        f"git -c user.name=tenant -c user.email=tenant@example.com commit -q -m '{message}' && "
        "git push -q origin main"
    )
    return run.succeed("git -C /work rev-parse HEAD").strip()


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
    run.succeed(f"grep -x {good} {STATE}/deployed")
    run.wait_until_succeeds("docker exec tenant-cron-1 true", timeout=60)
    run.succeed("docker exec tenant-cron-1 printenv GREETING | grep -x hello-from-sops")
    m = metrics()
    assert "tenant_deploy_success 1" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    assert f'tenant_deploy_info{{commit="{good}"}} 1' in m, m
    # The decrypted secrets were the run's alone.
    run.fail("test -e /run/tenant-deploy")
    run.fail("systemctl is-failed tenant-deploy.service")

with subtest("an unchanged main is not deployed again"):
    run.succeed("systemctl start tenant-deploy.service")
    run.succeed(
        f"journalctl -u tenant-deploy.service -o cat | grep -F 'main is still {good}, already deployed'"
    )

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

with subtest("a broken commit fails the unit and posts to the tenant's webhook once"):
    run.succeed("echo 'RUN exit 1' >> /work/Dockerfile")
    broken = commit("broken")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("test -e /tmp/webhook/000.json", timeout=60)
    body = json.loads(run.succeed("cat /tmp/webhook/000.json"))
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
    assert posts() == 1

with subtest("negative control: with the receiver stopped, the handler's post fails"):
    run.succeed("systemctl stop webhook.service")
    run.succeed("echo '# again' >> /work/Dockerfile")
    commit("broken again")
    run.fail("systemctl start tenant-deploy.service")
    run.wait_until_succeeds("systemctl is-failed tenant-deploy-failed.service", timeout=60)
    run.succeed(
        "journalctl -u tenant-deploy-failed.service -o cat | grep -i 'curl.*\\(connect\\|refused\\)'"
    )
    assert posts() == 1
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
    assert posts() == 1

with subtest("fixing the commit deploys again"):
    encrypt(AGE_PUB)
    fixed = commit("fixed")
    run.succeed("systemctl start tenant-deploy.service")
    m = metrics()
    assert "tenant_deploy_success 1" in m, m
    assert "tenant_deploy_platform_ok 1" in m, m
    assert f'tenant_deploy_info{{commit="{fixed}"}} 1' in m, m
