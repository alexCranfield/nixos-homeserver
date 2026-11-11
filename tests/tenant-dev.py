HOME = "/var/home/tenant"
STATE = "/var/lib/tenant-dev"
SSH = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"


def as_tenant(command, key="tenant"):
    """Run a command on dev over SSH, logged in as the tenant with a key."""
    return client.succeed(f"{SSH} -i /root/{key} tenant@dev {command!r}")


start_all()
dev.wait_for_unit("multi-user.target")
dev.wait_for_unit("sshd.service")
client.wait_for_unit("multi-user.target")
for name in ["tenant", "stranger"]:
    client.succeed(f"install -m 0600 {KEYS}/{name} /root/{name}")

with subtest("the tenant's home is in /var, theirs alone"):
    dev.succeed(f"getent passwd tenant | cut -d: -f6 | grep -x {HOME}")
    dev.succeed(f"stat -c '%U %a' {HOME} | grep -x 'tenant 700'")

with subtest("first boot makes the keys in the tenant's home, and publishes their public halves"):
    dev.wait_for_unit("tenant-dev-keys.service")
    dev.succeed(f"stat -c '%U %a' {HOME}/.ssh/id_ed25519 | grep -x 'tenant 600'")
    dev.succeed(f"stat -c '%U %a' {HOME}/.config/sops/age/keys.txt | grep -x 'tenant 600'")
    dev.succeed(f"grep -q '^ssh-ed25519 .* tenant-dev deploy key$' {STATE}/deploy_key.pub")
    dev.succeed(f"stat -c %a {STATE}/deploy_key.pub {STATE}/age.pub | sort -u | grep -x 644")
    AGE_PUB = dev.succeed(f"cat {STATE}/age.pub").strip()
    assert AGE_PUB.startswith("age1"), AGE_PUB
    dev.succeed(f"journalctl -u tenant-dev-keys -o cat | grep -F '{AGE_PUB}'")

with subtest("the keys survive a restart of their unit, and a lost public half is made again"):
    before = dev.succeed(f"cat {STATE}/deploy_key.pub {STATE}/age.pub {HOME}/.ssh/id_ed25519")
    dev.succeed("systemctl restart tenant-dev-keys.service")
    assert dev.succeed(f"cat {STATE}/deploy_key.pub {STATE}/age.pub {HOME}/.ssh/id_ed25519") == before
    dev.succeed(f"rm {HOME}/.ssh/id_ed25519.pub")
    dev.succeed("systemctl restart tenant-dev-keys.service")
    # The same key; ssh-keygen -y keeps its comment.
    assert dev.succeed(f"cat {STATE}/deploy_key.pub {STATE}/age.pub {HOME}/.ssh/id_ed25519") == before

with subtest("the tenant logs in with their key, and has Claude Code, sudo and Docker"):
    out = as_tenant("claude --version")
    assert "Claude Code" in out, out
    as_tenant("sudo -n true")
    as_tenant("docker info >/dev/null")
    for tool in ["git", "gh", "sops", "age", "node", "jq"]:
        as_tenant(f"command -v {tool}")
    # The key comes from the credential, in a file they can't edit.
    dev.succeed("stat -c '%U %a' /run/tenant-ssh/tenant | grep -x 'root 644'")

with subtest("negative control: another key is refused, for the tenant and for ops"):
    client.fail(f"{SSH} -i /root/stranger tenant@dev true")
    client.fail(f"{SSH} -i /root/tenant ops@dev true")

with subtest("a key added to ~/.ssh/authorized_keys doesn't log in: sops is the only source"):
    dev.succeed(f"install -o tenant -m 0600 {KEYS}/stranger.pub {HOME}/.ssh/authorized_keys")
    client.fail(f"{SSH} -i /root/stranger tenant@dev true")
    dev.succeed(f"rm {HOME}/.ssh/authorized_keys")

with subtest("a key credential that isn't one public key fails its unit"):
    dev.succeed(f"cp {KEYS}/tenant.pub /tmp/good.pub")
    dev.succeed("cat /etc/tenant-ssh-key /etc/tenant-ssh-key > /tmp/two.pub")
    dev.succeed("mount --bind /tmp/two.pub /etc/tenant-ssh-key")
    dev.fail("systemctl restart tenant-ssh-key.service")
    dev.succeed("umount /etc/tenant-ssh-key")
    dev.succeed("systemctl restart tenant-ssh-key.service")
    as_tenant("true")

with subtest("the dev VM's age key can't decrypt a file encrypted to another key"):
    # As secrets/prod.yaml is encrypted to the runner and the tenant, never
    # to the dev VM.
    dev.succeed("age-keygen -o /tmp/runner.key")
    runner = dev.succeed("age-keygen -y /tmp/runner.key").strip()
    dev.succeed(f"echo 'secret: prod' | age -r {runner} -a > /tmp/prod.age && chmod 644 /tmp/prod.age")
    as_tenant(f"! age -d -i {HOME}/.config/sops/age/keys.txt /tmp/prod.age")
    # Negative control: one encrypted to the dev VM's key decrypts.
    dev.succeed(f"echo 'secret: dev' | age -r {AGE_PUB} -a > /tmp/dev.age && chmod 644 /tmp/dev.age")
    out = as_tenant(f"age -d -i {HOME}/.config/sops/age/keys.txt /tmp/dev.age")
    assert out.strip() == "secret: dev", out

with subtest("tailscaled runs, and only SSH is open on its interface"):
    dev.wait_for_unit("tailscaled.service")
    rules = "nft list ruleset | grep -F 'iifname \"tailscale0\"'"
    dev.succeed(f"{rules} | grep -q 'tcp dport 22 accept'")
    dev.fail(f"{rules} | grep -v 'tcp dport 22 accept'")
