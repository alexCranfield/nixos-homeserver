# tenant-run's deploy, run by tenant-deploy.service every 5 minutes
# (./runner.nix): fetch the tenant's private repo's `main`, check that its CI
# (continuous integration) passed on that commit, decrypt its production
# secrets, and bring its Compose stack up to that commit.
#
# The CI check is the production gate: the private repo's plan can't enforce
# a ruleset, so a push to `main` is possible, but a commit whose CI hasn't
# passed is never deployed (ADR 0013). It asks GitHub's Actions API for the
# commit's runs of event `push`: none yet, or any still running, is a wait;
# all succeeded (or skipped) is a pass; anything else is a failure, the
# tenant's to fix.
#
# State, all in /var (the VM's one persistent volume):
#   $state/keys/        the deploy key and the age key (tenant-runner-keys)
#   $state/repo/        the checkout
#   $state/deployed     the commit last brought up, and the boot it was in
#   $state/metrics/     node-exporter's textfile directory
# and in /run/tenant-runner (tmpfs, kept between runs until a reboot):
#   stage, commit       where this run got to (fetch, checks, ci, decrypt,
#                       compose; `done` once it succeeded or is waiting for
#                       CI), for tenant-deploy-failed
#   webhook             the tenant's FAILURE_WEBHOOK, from the last decrypt
#
# The repository's URL is the credential `repo-url`, and a read-only GitHub
# token for its Actions runs the credential `ci-token`; $TENANT_CI_API is the
# API's address. The decrypted secrets and the token's header exist only in
# $RUNTIME_DIRECTORY, which systemd removes when the run ends.
state=/var/lib/tenant-runner
repo=$state/repo
run=/run/tenant-runner
metrics=$state/metrics

stage() { printf '%s\n' "$1" >"$run/stage"; }

# Metrics: whether the last run deployed, whether the platform's part of it
# (fetching and decrypting) worked, when a run last ended (Alex's alert on a
# runner that stopped deploying at all), when it last deployed and which
# commit.
write_metrics() {
  local success=$1 platform_ok=$2 last commit
  last=$(cat "$state/last-success" 2>/dev/null || echo 0)
  commit=$(cut -d' ' -f1 "$state/deployed" 2>/dev/null || echo none)
  cat >"$metrics/tenant_deploy.prom.tmp" <<EOF
# HELP tenant_deploy_success Whether the last deploy run succeeded.
# TYPE tenant_deploy_success gauge
tenant_deploy_success $success
# HELP tenant_deploy_platform_ok Whether the last run fetched and decrypted, the platform's part.
# TYPE tenant_deploy_platform_ok gauge
tenant_deploy_platform_ok $platform_ok
# HELP tenant_deploy_last_run_timestamp_seconds When a deploy run last ended, either way.
# TYPE tenant_deploy_last_run_timestamp_seconds gauge
tenant_deploy_last_run_timestamp_seconds $(date +%s)
# HELP tenant_deploy_last_success_timestamp_seconds When a deploy last succeeded.
# TYPE tenant_deploy_last_success_timestamp_seconds gauge
tenant_deploy_last_success_timestamp_seconds $last
# HELP tenant_deploy_info The commit the stack runs.
# TYPE tenant_deploy_info gauge
tenant_deploy_info{commit="$commit"} 1
EOF
  # node-exporter reads it as a user of its own; the unit's umask is 077.
  chmod 0644 "$metrics/tenant_deploy.prom.tmp"
  mv "$metrics/tenant_deploy.prom.tmp" "$metrics/tenant_deploy.prom"
}

# Any way out but the two that write their own metrics is a failure,
# including systemd's TERM at the timeout, after which the EXIT trap would
# otherwise see status 0.
finished=
on_exit() {
  if [ -z "$finished" ]; then
    case $(cat "$run/stage") in
      ci | compose) write_metrics 0 1 ;;
      *) write_metrics 0 0 ;;
    esac
  fi
}
trap on_exit EXIT
trap 'exit 143' TERM

stage fetch
: >"$run/commit"
url=$(cat "$CREDENTIALS_DIRECTORY/repo-url")
[ -n "$url" ] || {
  echo "the repo-url credential is empty" >&2
  exit 1
}
export GIT_SSH_COMMAND="ssh -i $state/keys/deploy_key -o IdentitiesOnly=yes -o BatchMode=yes \
  -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
[ -d "$repo/.git" ] || git init --quiet --initial-branch=main "$repo"
git -C "$repo" fetch --quiet --depth=1 "$url" main
commit=$(git -C "$repo" rev-parse FETCH_HEAD)
printf '%s\n' "$commit" >"$run/commit"

# Deployed in this boot: a reboot brings the stack up again, since a
# container without a restart policy stays down.
current="$commit $(cat /proc/sys/kernel/random/boot_id)"
if [ "$current" = "$(cat "$state/deployed" 2>/dev/null)" ]; then
  echo "main is still $commit, already deployed"
  write_metrics 1 1
  stage "done"
  finished=1
  exit 0
fi
echo "deploying $commit"

stage checks
# owner/repo: $TENANT_CI_REPO if set, else from either form of GitHub's URLs.
slug=${TENANT_CI_REPO:-$(sed -E 's#^(ssh://)?git@github\.com[:/]##; s#^https://github\.com/##; s#\.git$##' <<<"$url")}
# In a file, not in curl's arguments, where `ps` would show it.
printf 'Authorization: Bearer %s\n' "$(cat "$CREDENTIALS_DIRECTORY/ci-token")" >"$RUNTIME_DIRECTORY/auth"
# A redirect (the repo renamed or moved) is an error, not an empty answer:
# `--location` with no redirects allowed makes curl fail on one.
runs=$(curl --fail --silent --show-error --max-time 20 --location --max-redirs 0 \
  --header @"$RUNTIME_DIRECTORY/auth" --header 'Accept: application/vnd.github+json' \
  "$TENANT_CI_API/repos/$slug/actions/runs?head_sha=$commit&event=push&branch=main&per_page=50")
# An answer without the list is an error too, never "no runs yet"; so is an
# empty one, for which -e makes jq fail rather than print nothing.
ci=$(jq -e -r '(.workflow_runs // error("no workflow_runs in the answer"))
  | if length == 0 or any(.[]; .status != "completed") then "pending"
    elif all(.[]; .conclusion == "success" or .conclusion == "skipped") then "success"
    else "failure" end' <<<"$runs")
case $ci in
  pending)
    # Not a failure: the stack keeps running what it runs, and the metrics
    # keep the last run's verdict. Unless it never ends: a commit whose CI
    # hasn't passed in 6 hours (`[skip ci]`, a workflow that no longer runs
    # on push) is the tenant's to fix, so it fails as CI.
    since=$(sed -n "s/^$commit //p" "$state/pending" 2>/dev/null || true)
    if [ -z "$since" ]; then
      since=$(date +%s)
      printf '%s %s\n' "$commit" "$since" >"$state/pending"
    fi
    if [ $(($(date +%s) - since)) -gt 21600 ]; then
      stage ci
      echo "CI has not passed on $commit in 6 hours: not deployed"
      exit 1
    fi
    echo "CI has not finished on $commit: deploying it once it passes"
    previous=$(sed -n 's/^tenant_deploy_success //p' "$metrics/tenant_deploy.prom" 2>/dev/null || true)
    write_metrics "${previous:-1}" 1
    stage "done"
    finished=1
    exit 0
    ;;
  failure)
    stage ci
    echo "CI failed on $commit: not deployed"
    jq -r '.workflow_runs[] | "  \(.name): \(.conclusion) \(.html_url)"' <<<"$runs"
    exit 1
    ;;
  success) ;;
  *)
    echo "unexpected CI verdict '$ci' for $commit" >&2
    exit 1
    ;;
esac
echo "CI passed on $commit"
rm -f "$state/pending"

git -C "$repo" checkout --quiet --force --detach "$commit"
git -C "$repo" clean --quiet -ffdx

stage decrypt
env=$RUNTIME_DIRECTORY/prod.env
if [ -e "$repo/secrets/prod.yaml" ]; then
  SOPS_AGE_KEY_FILE=$state/keys/age.key sops --decrypt --output-type dotenv \
    "$repo/secrets/prod.yaml" >"$env"
else
  echo "no secrets/prod.yaml: the stack gets no secrets"
  : >"$env"
fi
webhook=$(sed -n 's/^FAILURE_WEBHOOK=//p' "$env")
if [ -n "$webhook" ]; then
  printf '%s\n' "$webhook" >"$run/webhook"
else
  rm -f "$run/webhook"
fi

stage compose
cd "$repo"
TENANT_SECRETS=$env TENANT_JOB_METRICS=$state/job-metrics \
  docker compose --project-name tenant up --detach --build --remove-orphans \
  --wait --wait-timeout 600
# Done before the bookkeeping, so a TERM between these lines can't record
# (and post) a failure for a deploy that is up.
finished=1
printf '%s\n' "$current" >"$state/deployed"
date +%s >"$state/last-success"
write_metrics 1 1
stage "done"
echo "deployed $commit"
# Housekeeping, not part of the deploy.
docker image prune --force >/dev/null || echo "pruning images failed"
