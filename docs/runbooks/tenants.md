# Tenant VMs

The tenant's dev environment and job runner, two microVMs (virtual machines)
on the nuc: `tenant-dev` and `tenant-run`. Why they are VMs, and what they may
reach, is ADR (Architecture Decision Record) 0013. The code is in
`modules/tenants/` and `hosts/nuc/tenants.nix`.

This runbook grows with tickets 6.7 to 6.12 (#197 to #202). So far: the VMs
(6.8), their network and the state directory (6.7), the runner (6.9) and the
dev VM (6.10).

## The VMs

| VM | vCPU | RAM | `/var` | Host-side memory ceiling |
|---|---|---|---|---|
| `tenant-dev` | 4 | 8 GB | 60 GB | 9 GB for qemu, 1 GB for its virtiofsd |
| `tenant-run` | 2 | 4 GB | 30 GB | 5 GB for qemu, 1 GB for its virtiofsd |

Each is a microvm.nix guest on qemu, built from `modules/tenants/guest-base.nix`
and run by `microvm@<name>.service`, which starts at boot. A VM's CPU and I/O
weights are half the default, so the game servers and LLMs win any
contention. A VM that fails posts to Discord.

```bash
systemctl status microvm@tenant-dev
sudo systemctl restart microvm@tenant-dev   # a reboot of the VM
journalctl -u microvm@tenant-dev            # qemu's side; the guest's own log is inside it
```

**Inside a VM:**
- **Root:** the root filesystem is tmpfs, rebuilt from the configuration at every boot.
- **What persists:** only `/var`, an ext4 image at `/var/lib/microvms/<name>/var.img` on the host. That covers the SSH host keys (`/var/lib/ssh`), the journal, and later Docker and the tenant's work.
- **Store:** the host's `/nix/store` is shared in read-only by `microvm-virtiofsd@<name>`, which runs as root on the host with `--readonly`. A deploy updates the VM's software, and the VM restarts when its configuration changes.
- **Sizes:** the `/var` image is sparse and is made once. Changing `varSize` later doesn't resize it; that needs the VM stopped and the image grown by hand (`truncate`, then `resize2fs` inside).

**SSH in.** A VM accepts SSH from the nuc's address alone, so go through the nuc:

```bash
ssh -J ops@nuc ops@10.88.0.2     # tenant-dev
ssh -J ops@nuc ops@10.88.0.3     # tenant-run
```

Never forward your SSH agent (`-A`) into a VM. The tenant is root in
`tenant-dev`, and could use a forwarded agent to log in anywhere your keys
are accepted, the nuc included.

**Secrets** reach a VM as systemd credentials:
- The host names a file per credential (`microvm.credentialFiles` in the VM's configuration), and qemu passes it in. qemu runs as the `microvm` user, so a host-side secret must be readable by that user.
- Inside, the credential sits in `/run/credentials/@system`, readable by root. A unit that declares `LoadCredential=<name>` gets its own copy, readable by that unit alone.
- `probe`, in both VMs, isn't a secret; `tenant-credential-check.service` reads it to show the path works.
- `repo-url`, in `tenant-run`: the private repo's URL, from `repo_url` in `secrets/tenant.yaml` (below).
- `tenant-ssh-key` and `tailscale-auth-key`, in `tenant-dev`: the tenant's SSH public key and the VM's Tailscale auth key, from `dev_ssh_key` and `dev_tailscale_auth_key` (below).

**Smoke test.** From the workstation, after any change to the tenant
network, firewall or DNS:

```bash
just tenant-smoke
```

The recipe first checks, from the nuc, that the targets the VMs must not
reach do answer (the router's 443 and 53, the nuc's SSH on the tailnet, each
VM's SSH), so a blocked probe means a block, not a closed port. Then it runs
`modules/tenants/smoke.sh` inside each VM. That VM must reach:
- the internet;
- its own Blocky, which blocks ads and returns NXDOMAIN (no such name) for every LAN name.

It must not reach:
- the LAN's Blocky;
- the router, including its console on the public address;
- the nuc's SSH, on both the tenant network and the tailnet;
- a Docker published port (Minecraft's 25565: a real probe only while that stack is up);
- the other VM, by ping, which it answers from anywhere;
- the LAN by ping.

The recipe exits non-zero if any probe goes the wrong way.

## The runner

`tenant-run` deploys the tenant's private repo (`modules/tenants/runner.nix`,
6.9). Every 5 minutes `tenant-deploy.service` runs `modules/tenants/deploy.sh`:
1. **Fetch:** fetch `main` with the VM's deploy key. If it's the commit already deployed in this boot, stop there. After a reboot the same commit is deployed again, so the stack comes back even where a container has no restart policy.
2. **CI (continuous integration):** ask GitHub's Actions API for the commit's workflow runs from its push to `main` (`event=push&branch=main`). This is the production gate, since the private repo's plan can't enforce a ruleset (ADR 0013).
   - **Wait:** no run yet, or one still running. Nothing changes; the next run asks again. After 6 hours of waiting (`[skip ci]`, a workflow that no longer runs on push) the commit counts as failed.
   - **Pass:** every run succeeded or was skipped. Go on.
   - **Fail:** anything else, a cancelled run included. The tenant hears, and the commit is never deployed.
   - An answer that isn't a list of runs (a redirect from a renamed repo, an error body) is the platform's fault, not a wait.
3. **Decrypt:** decrypt `secrets/prod.yaml` with the VM's age key into a dotenv file that only this run can read; systemd removes it when the run ends.
4. **Docker:** `docker info` must answer within 60 seconds. If it doesn't, the run fails as the platform's fault, not the tenant's (#215).
5. **Compose:** `docker compose --project-name tenant up --detach --build --remove-orphans --wait --wait-timeout 600` in the checkout.
6. **Settle:** `--wait` returns as soon as each container runs, so one that crashes a second later would pass it (#210). The deploy waits 30 seconds (`homeserver.tenantRunner.settleSeconds`), then fails if any of the stack's containers has restarted since `compose up`, is restarting, or has stopped with a non-zero status. A container that crashed before this deploy and that the deploy left alone counts only if it restarts again during the wait, or if it is still stopped with a failure. `docker compose run` containers don't count. A single restart while the stack starts (an app waiting for its database) fails the deploy too; the next run, finding the same containers up, then deploys the commit, so the tenant may get a failure post for a commit that ends up deployed. Once it passes, the commit counts as deployed and unused images are pruned.

**Keys.** The VM makes its own keys on first boot (`tenant-runner-keys.service`)
and keeps them in `/var/lib/tenant-runner/keys`. They never leave the VM, so
they aren't in sops. Only their public halves are readable:

```bash
ssh -J ops@nuc ops@10.88.0.3 cat /var/lib/tenant-runner/deploy_key.pub /var/lib/tenant-runner/age.pub
```

**Setting it up**, once (and again after the VM's `/var` is lost, which makes new keys):
1. **In sops.** Run `sops secrets/tenant.yaml` on the workstation, with two keys:
   - `repo_url`: the repo's SSH clone URL (`git@github.com:<owner>/<repo>.git`). This repository is public, so the URL is only ever in that file.
   - `ci_token`: a fine-grained GitHub token for that repo alone, with **Actions: Read-only** and nothing else, expiring in a year. The runner asks with it whether a commit's CI passed.
2. **Deploy and read the keys.** Once comin has deployed, read the two public keys with the command above.
3. **Deploy key.** Add `deploy_key.pub` to the private repo as a deploy key (Settings → Deploy keys), with "Allow write access" left unticked.
4. **age recipient.** Add the age recipient to the private repo's `.sops.yaml` rule for `secrets/prod.yaml`, beside the tenant's own key. Then run `sops updatekeys secrets/prod.yaml` there and merge it. Never add it to `secrets/dev.yaml`, so the dev VM and its agent can't read production secrets.

**What the tenant's stack gets.** The deploy runs Compose with two variables,
which the repo's `compose.yml` uses:
- `TENANT_SECRETS` is the decrypted dotenv file, for `env_file: ${TENANT_SECRETS}`. Docker copies the values into each container's configuration on `/var`, as with any `env_file`.
- `TENANT_JOB_METRICS` is a directory for a bind mount. A job writes `<job>.prom` there, holding `tenant_job_last_exit{job="<job>"}` and `tenant_job_last_run_timestamp_seconds{job="<job>"}`. Every minute `tenant-job-metrics.service` copies the lines that name a `tenant_job_*` series, one sample per line, to node-exporter; it drops everything else.
- `FAILURE_WEBHOOK` in `secrets/prod.yaml` is where failed deploys are posted. It takes a Discord or Slack incoming-webhook URL.
- `--wait` needs every service to keep running (or turn healthy) within 10 minutes. A one-off container that exits fails the deploy, even with status 0 (Compose's `container … exited (0)`, seen while testing #210).

**When a deploy fails:**
- **In the tenant's own code** (CI failed on the commit, a build or a container that won't start or won't stay up, or a run stopped at its 30-minute timeout, or by hand with `systemctl stop`): `tenant-deploy-failed.service` posts the run's last 30 log lines (at most 1500 characters) to `FAILURE_WEBHOOK`, once per commit. The next run retries. Where the failure came before `compose up` replaced the containers (CI, the build), the last good commit keeps running. Where a container didn't stay up, the containers already run the new commit; the post ends with each failing container's last 5 log lines and a line saying so. A CI failure is posted with the webhook from the last decrypt, so it can't be posted after a reboot of the VM until a commit has got as far as decrypting.
- **Fetching, asking about CI, decrypting, or reaching Docker:** this is the platform's fault, and the tenant isn't told. The cause is a deploy key or age recipient that hasn't been added, a wrong URL, an expired or revoked `ci_token`, GitHub being down, a `prod.yaml` not encrypted to the runner, or a Docker daemon that won't start or has hung. The metric `tenant_deploy_platform_ok` drops to 0, and after 30 minutes `TenantDeployFailing` posts to Alex's alerts channel.

```bash
ssh -J ops@nuc ops@10.88.0.3
sudo systemctl start tenant-deploy            # deploy now instead of within 5 minutes
journalctl -u tenant-deploy -u tenant-deploy-failed
sudo rm /var/lib/tenant-runner/deployed       # force a redeploy of the same commit
sudo cat /run/tenant-runner/stage             # where the last run got to: fetch, checks, ci, decrypt, docker, compose, done
sudo docker compose -p tenant ps              # the stack
curl -s localhost:9100/metrics | grep ^tenant_
```

**Metrics and alerts.**
- Prometheus on the host scrapes the VM's node-exporter at `10.88.0.3:9100`, as the job `tenant-run`. It keeps only:
  - the `tenant_*` series: `tenant_deploy_success`, `tenant_deploy_platform_ok`, `tenant_deploy_last_run_timestamp_seconds`, `tenant_deploy_last_success_timestamp_seconds`, `tenant_deploy_info{commit}`, the jobs', and for each of the stack's containers `tenant_container_running{container}`, `tenant_container_exit_code{container}` and `tenant_container_restarts_total{container}` (Docker's restart count). `tenant-job-metrics.service` reads the containers' from Docker every minute and writes them in a file of its own, so no job's file can set them. If Docker can't be asked within 20 seconds, it deletes that file, so the series stop rather than report a stack that may be gone. Either way it writes `tenant_docker_up` (1 or 0) to a third file, `tenant_docker.prom`. A job's own `job` label becomes `exported_job` in Prometheus, since `job` is the scrape job's (`tenant-run`);
  - the VM's filesystem sizes, renamed `tenant_filesystem_*` so the host's own disk alerts never read them.
- Alex's alerts (`modules/observability/rules.nix`, group `homeserver-tenants`):
  - `TenantDeployFailing`: the fetch, the CI check, the decrypt or the Docker check has failed for 30 minutes;
  - `TenantDeployStale`: no deploy run, good or bad, has ended for 40 minutes (longer than a run's 5-minute wait plus its 30-minute timeout), held for 15 more. The timer has stopped, a run hangs, or the unit fails before its script (its keys, its `repo-url` credential). It also fires for a runner that answers scrapes but has never written its file;
  - `TenantDockerDown`: Docker in the runner hasn't answered for 5 minutes (`tenant_docker_up` 0), or the runner answers scrapes but has never written the series (its metrics timer never ran). The tenant's jobs may not be running (a hung daemon usually leaves the containers up) and nothing deploys, and the tenant isn't told. Docker starts on demand from `docker.socket`, so this is a daemon that won't start or has hung, not one that was merely stopped;
  - `TenantRunnerDown`: no scrape for 5 minutes, unless `microvm@tenant-run` has failed, which the notifier posts;
  - `TenantDiskFull`: `/var` is above 85% full for 10 minutes;
  - `TenantVmRestartLoop`: a tenant VM's `microvm@` unit has restarted more than twice in 30 minutes. It restarts forever and so never reaches the failed state.
  - `TenantStackRestarting`: one of the stack's containers has restarted more than twice in 15 minutes, held for 10. It crashes and its restart policy brings it back, so its jobs don't run. This catches a crash loop that starts long after a good deploy, which the deploy's settle check can't see; after a failed settle the tenant has had a post and Alex gets this one too.
  - `TenantStackDown`: a container has stopped with a non-zero status and hasn't been restarted for 15 minutes (restart policy `no`, or `on-failure` that gave up), held for 15. A container that exited 0 isn't down, and one in a crash loop is `TenantStackRestarting`'s.
- The tenant has root over their stack, and so over the VM, so they could write false metrics, which would hide a failed deploy from `TenantDeployFailing` too. The host's own view of the VM (`up`, `microvm@`) is out of their reach.

## The dev VM

`tenant-dev` is where the tenant works (`modules/tenants/dev.nix`, 6.10):
- **Login:** user `tenant`, over a Tailscale share (`ssh tenant@tenant-dev.<tailnet name>.ts.net` from their own device), with the public key `dev_ssh_key` from `secrets/tenant.yaml`. The VM reads it into `/run/tenant-ssh/tenant`, a file the tenant can't edit, and reads no `~/.ssh/authorized_keys`, so replacing the key in sops cuts the old one off. `dev_ssh_key` holds exactly one key, so the tenant uses the same key from each of their devices. They are root in the VM, so they could still let another key in until it restarts; the Tailscale share is what decides who reaches it at all.
- **Home:** `/var/home/tenant`, on the persistent `/var`, so it survives restarts and deploys. So does Docker's data. Everything else outside the store is lost at each boot: install tools in the home, or ask Alex to add them to `dev.nix`.
- **Rights:** passwordless sudo, and Docker.
- **Tools:** git, gh, sops, age, Node.js, jq, Python 3.13, uv and Claude Code. They come from this repo's nixpkgs, so Claude Code updates when the flake is bumped, not by itself. The tenant logs Claude Code in with their own account.
- **Programs from outside Nix:** nix-ld is on (#219), so a standalone program built for any Linux runs: ruff and other tools that `uv sync` installs from PyPI (the Python Package Index), and the Pythons uv downloads when a project asks for a version other than the system's. Without it NixOS refuses them ("Could not start dynamically linked executable"). The VM's read-only store means the tenant can't add Nix packages themselves, and this is their way round it; the VM, not the store, is what contains what they run.
- **Not covered:** a wheel with native libraries it doesn't bundle (one needing libstdc++, say), imported by the system Python, fails with "cannot open shared object file". nix-ld's libraries reach only programs started through its loader. Run it with `LD_LIBRARY_PATH=$NIX_LD_LIBRARY_PATH`, or in a uv-managed Python (`uv python install 3.13 && uv venv --python-preference only-managed`), which starts through nix-ld. The private repo's tools (ruff, pytest) don't need either.
- **Tailscale:** its own `tailscaled`, tagged `tag:tenant-dev`, with only port 22 open on `tailscale0`. Its lookups stay on the tenants' Blocky (`--accept-dns=false`), not MagicDNS. The tag is never a source in the policy, so the VM can't start a connection to any device on the tailnet; the host's rules keep it off the LAN whatever its Tailscale flags say.
- **GitHub:** `~/.ssh/id_ed25519` is a deploy key with write access on the private repo and nothing else. `git push` works with it; pull requests are opened in the browser, or with `gh` if the tenant logs it in with their own account, which would give anything in the VM their whole GitHub account.
- **Secrets:** `~/.config/sops/age/keys.txt`, where sops looks by default, is the VM's age key. It is a recipient of `secrets/dev.yaml` in the private repo and never of `prod.yaml`, so nothing in dev decrypts production. The tenant's own age key is never copied in.

`tenant-dev-keys.service` makes both keys on first boot, as the tenant, and
leaves existing ones alone. Their public halves are copied to where Alex can
read them:

```bash
ssh -J ops@nuc ops@10.88.0.2 cat /var/lib/tenant-dev/deploy_key.pub /var/lib/tenant-dev/age.pub
```

**Setting it up**, once (and again after the VM's `/var` is lost, which makes new keys and a new tailnet device):
1. **The tailnet.** Add `tag:tenant-dev` and its grant to the access policy, and generate its auth key, as in [tailscale.md](tailscale.md).
2. **In sops.** Run `sops secrets/tenant.yaml` on the workstation and add:
   - `dev_tailscale_auth_key`: that auth key;
   - `dev_ssh_key`: the tenant's SSH public key, one line (`ssh-ed25519 AAAA… comment`). `tenant-ssh-key.service` fails on anything else.
   Both must be there before the change that adds them is deployed: the host's sops-nix refuses to activate with a key missing.
3. **Deploy and read the keys** with the command above.
4. **Deploy key.** Add `deploy_key.pub` to the private repo (Settings → Deploy keys) with "Allow write access" ticked. It reaches that repo alone.
5. **age recipient.** Add `age.pub` to the private repo's `.sops.yaml` rule for `secrets/dev.yaml` only, then `sops updatekeys secrets/dev.yaml` there and merge.
6. **Share** the device with the tenant ([tailscale.md](tailscale.md)).

**Checking it**, after setup:
- From the tenant's device: `ssh tenant@tenant-dev.<tailnet name>.ts.net`, then `claude --version`.
- From inside the VM: `tailscale status` lists the VM and the tenant's devices only. A connection to the nuc's tailnet address, or any other device's, is refused: `nc -zv -w 5 <100.x address> 22` times out.
- `just tenant-smoke` still passes: the LAN, the router and the nuc stay closed.
- A push to `main` from the VM is deployed only once its CI passes on GitHub (the runner's gate, above).

## The tenant's lifecycle

The tenant's side, a template of scheduled jobs, lives in their private repo
with its own README. This section is the platform's side.

**Onboarding.**
1. **Repo.** Create the private repo under Alex's account, and add the tenant as a collaborator.
2. **Runner.** Set it up as in "Setting it up" above: `repo_url` and `ci_token` in sops, then the deploy key and the age recipient on the repo.
3. **Secrets.** Encrypt the repo's `secrets/prod.yaml` to the runner and to the tenant's own age key, and `secrets/dev.yaml` to the dev VM's key and theirs.
   - Until the tenant has a key, Alex's workstation key stands in for theirs, so Alex can enter `FAILURE_WEBHOOK`.
   - Swap it with `sops updatekeys` when they take over.
4. **Dev VM.** Set it up and share it with the tenant, as in "The dev VM" above.

**Rotating a key or token.**
- **The deploy key or the runner's age key:** delete the key and its public copy, and restart `tenant-runner-keys`, which makes new ones. For the deploy key:

  ```bash
  ssh -J ops@nuc ops@10.88.0.3 'sudo rm /var/lib/tenant-runner/keys/deploy_key{,.pub} /var/lib/tenant-runner/deploy_key.pub'
  ssh -J ops@nuc ops@10.88.0.3 'sudo systemctl restart tenant-runner-keys'
  ```

  Then replace the deploy key on the repo. For the age key (`keys/age.key` and `age.pub`), replace the recipient in the repo's `.sops.yaml` and run `sops updatekeys secrets/prod.yaml` there.
- **`ci_token`:** make a new token as in "Setting it up", put it in `secrets/tenant.yaml`, and revoke the old one once comin has deployed. An expired token stops every deploy, and `TenantDeployFailing` says so after 30 minutes.
- **The dev VM's keys:** as the runner's, in the tenant's home: `~/.ssh/id_ed25519{,.pub}` and `~/.config/sops/age/keys.txt`, then `sudo systemctl restart tenant-dev-keys` and replace them on the repo. The tenant can do this themselves.
- **The dev VM's Tailscale auth key** is used once, at the VM's first join, and its state is then in `/var`. A new one is needed only if `/var` is lost: generate it and replace `dev_tailscale_auth_key` in sops.
- **The tenant's SSH key:** replace `dev_ssh_key` in sops. When comin deploys it, sops-nix restarts `microvm@tenant-dev` (the VM reads its credentials at boot only), which ends any session in it. For a key that may be stolen, revoke the Tailscale share first: that cuts the tenant's devices off at once.

**Reading the platform's alerts.** A tenant alert in Discord names the VM
(`job="tenant-run"`). Check the runner's journal (the commands above) and
`stage`:
- **`fetch`:** the deploy key or the URL.
- **`checks`:** `ci_token`, or GitHub's API.
- **`decrypt`:** the age recipient.
- **`docker`:** Docker itself, as for `TenantDockerDown`.

`TenantDeployStale` with no stage change means the timer or the keys unit;
look at `systemctl status tenant-deploy.timer tenant-runner-keys`.

`TenantDockerDown`: in the VM, `systemctl status docker.socket docker.service`
and `journalctl -u docker -n 50`. A full `/var` (`TenantDiskFull`) stops
dockerd starting; a hung one needs `sudo systemctl restart docker`. Once it
answers, containers with a restart policy come back by themselves, and the
next deploy run deploys a commit that failed at the Docker check, which was
never recorded as deployed. If `main` hasn't changed, force a redeploy with
`sudo rm /var/lib/tenant-runner/deployed`.

`TenantStackRestarting` and `TenantStackDown` name the container. The
cause is nearly always the tenant's code: read its log with
`sudo docker logs --tail 50 <container>` in the VM, and pass it on to the
tenant. A deploy of a fixed commit replaces the container and resets its
count. The platform's causes are a full `/var` (`TenantDiskFull`) and the
VM's memory (`dmesg | grep -i oom`).

**Offboarding.**
1. Revoke the dev VM's Tailscale share, and remove the device from the Machines page.
2. Remove the VMs from `hosts/nuc/tenants.nix` and their secrets from `secrets/tenant.yaml`, and merge.
3. Delete their images on the nuc: `sudo rm -r /var/lib/microvms/tenant-*`.
4. Delete both deploy keys (the runner's and the dev VM's) from the repo, and revoke `ci_token`.
5. Archive the private repo, or transfer it to the tenant.

## The network

| VM | Tap on the host | Address | Gateway |
|---|---|---|---|
| `tenant-dev` | `vm-tenant-dev` | 10.88.0.2/32 | 10.88.0.1 |
| `tenant-run` | `vm-tenant-run` | 10.88.0.3/32 | 10.88.0.1 |

The taps are routed, not bridged. The host holds 10.88.0.1/32 on each, with
a route to the VM's /32, and masquerades 10.88.0.0/24 out of `lan0`. A tap
exists only while its VM runs; boot doesn't wait for one.

A VM reaches the internet, and port 53 on 10.88.0.1, the tenants' own
Blocky (below). Nothing else, IPv4 only. The `tenant-isolation` nftables
table drops the rest:

```bash
sudo nft list table inet tenant-isolation
sudo nft list counter inet tenant-isolation forward-drops
sudo nft list counter inet tenant-isolation input-drops
```

- **forward**: private, shared (100.64/10, the tailnet's), link-local,
  multicast and reserved destinations, so the LAN (local area network), the
  router, Docker's networks and published ports, the tailnet and the other
  VM; the router's public address (below); any exit but `lan0`; all IPv6;
  and new connections to a VM.
- **input**: everything to the nuc itself except DNS (Domain Name System) to
  10.88.0.1, the LAN's Blocky included.

The table only drops. What a VM may do is opened in the usual places: port
53 on each tap in NixOS's firewall, and the forward accept `networking.nat`
adds. A port opened later to every interface still doesn't reach a VM.

Never name a new interface `br-…`: Docker's forward rule accepts all traffic
from those (`modules/containers/docker.nix`). VM names must start
`tenant-`, which the rules match and the flake check `tenant-names` enforces.

A rising drop counter means a VM tried something it may not. To see what, log
the drops for a while:

```bash
sudo nft insert rule inet tenant-isolation forward iifname '"vm-tenant-*"' log prefix '"tenant-drop "'
sudo journalctl -kf | grep tenant-drop
# remove it again (the handle is the number `nft -a` prints):
sudo nft -a list chain inet tenant-isolation forward
sudo nft delete rule inet tenant-isolation forward handle <n>
```

The next deploy also puts the table back as declared.

### The router's public address

The router answers on its public (WAN, wide area network) address from
inside the LAN, its console included, so that address is dropped too. It
changes, so it isn't in the configuration: `tenant-router-wan.service`
looks it up from Cloudflare's trace page (`https://1.1.1.1/cdn-cgi/trace`)
every five minutes and keeps it in the set `router-wan`. A reload of the
ruleset, as on every deploy that changes it, empties the set, and the
service puts the last address back at once from
`/var/lib/tenant-router-wan/address`.

```bash
sudo nft list set inet tenant-isolation router-wan   # one address
systemctl status tenant-router-wan.service
sudo systemctl reload tenant-router-wan.service       # look it up now
```

A failed lookup leaves the last address in place. Once lookups have failed
for 30 minutes since boot or since the last success, the unit fails, which
posts to Discord; a short outage, or the router's WAN coming up a few
minutes after its LAN after a power cut, doesn't. Between a change of
address and the next good lookup, the new address is open to the VMs.

### DNS

The VMs have a Blocky of their own, `blocky-tenant`, on 10.88.0.1 (also on
the dummy interface `tenant-dns`, so it can start before any VM). It has the
LAN Blocky's lists and asks the same Unbound, but answers none of the LAN's
names: no local records, no private hosts file, nothing forwarded to the
router. The LAN Blocky answers those before any per-client blocking, reverse
lookups included, so a VM that could ask it could read back the house's
device names; the VMs can't reach it.

It writes to the same query log, so the VMs show in the dashboard and the
DNS alerts as `tenant-dev` and `tenant-run`. The first lookups from each fire
`DnsNewClient` once.

```bash
systemctl status blocky-tenant.service
nix shell nixpkgs#dnsutils -c dig @10.88.0.1 example.com   # from the nuc, which has no dig
```

## The state directory

microvm.nix keeps each VM's runner and disk images under
`/var/lib/microvms`. It is its own btrfs subvolume with copy-on-write off
(NOCOW), so the images don't fragment, and it is left out of snapshots of
the root and of backups: no customer data from the tenant's jobs reaches the
NAS (network-attached storage).

`microvm-state.service` checks both when a VM first starts; every
`microvm@` unit requires it. If it fails, the VMs don't
start and the failure posts to Discord. To check by hand at any time:

```bash
sudo microvm-state-check
```

Never `systemctl restart microvm-state`: the restart passes on to every VM
that requires it. A deploy doesn't restart it either.

If the directory became a plain one, with no VMs on it yet:

```bash
sudo rmdir /var/lib/microvms        # refuses if anything is inside
sudo systemd-tmpfiles --create --prefix=/var/lib/microvms
sudo microvm-state-check
sudo systemctl reset-failed microvm-state.service
```

tmpfiles makes a subvolume there only because `/` is itself one (`@root`);
on a root that isn't, it quietly makes a plain directory, which the check
catches.

If images are already inside, stop the VMs and move the images out first;
NOCOW applies only to files created after it is set.
