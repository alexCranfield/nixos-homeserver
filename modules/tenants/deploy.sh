# tenant-run's deploy, run by tenant-deploy.service every 5 minutes
# (./runner.nix): fetch the tenant's private repo's `main`, decrypt its
# production secrets, and bring its Compose stack up to that commit.
#
# State, all in /var (the VM's one persistent volume):
#   $state/keys/        the deploy key and the age key (tenant-runner-keys)
#   $state/repo/        the checkout
#   $state/deployed     the commit last brought up successfully
#   $state/metrics/     node-exporter's textfile directory
# and in /run/tenant-runner (tmpfs, kept between runs until a reboot):
#   stage, commit       where this run got to, for tenant-deploy-failed
#   webhook             the tenant's FAILURE_WEBHOOK, from the last decrypt
#
# The repository's URL is the credential `repo-url`. The decrypted secrets
# exist only in $RUNTIME_DIRECTORY, which systemd removes when the run ends.
state=/var/lib/tenant-runner
repo=$state/repo
run=/run/tenant-runner
metrics=$state/metrics

stage() { printf '%s\n' "$1" >"$run/stage"; }

# Metrics: whether the last run deployed, whether the platform's part of it
# (fetching and decrypting) worked, when it last deployed and which commit.
write_metrics() {
  local success=$1 platform_ok=$2 last commit
  last=$(cat "$state/last-success" 2>/dev/null || echo 0)
  commit=$(cat "$state/deployed" 2>/dev/null || echo none)
  cat >"$metrics/tenant_deploy.prom.tmp" <<EOF
# HELP tenant_deploy_success Whether the last deploy run succeeded.
# TYPE tenant_deploy_success gauge
tenant_deploy_success $success
# HELP tenant_deploy_platform_ok Whether the last run fetched and decrypted, the platform's part.
# TYPE tenant_deploy_platform_ok gauge
tenant_deploy_platform_ok $platform_ok
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

on_exit() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    case $(cat "$run/stage") in
      compose) write_metrics 0 1 ;;
      *) write_metrics 0 0 ;;
    esac
  fi
}
trap on_exit EXIT

stage fetch
: >"$run/commit"
url=$(cat "$CREDENTIALS_DIRECTORY/repo-url")
[ -n "$url" ] || {
  echo "the repo-url credential is empty" >&2
  exit 1
}
export GIT_SSH_COMMAND="ssh -i $state/keys/deploy_key -o IdentitiesOnly=yes -o BatchMode=yes"
[ -d "$repo/.git" ] || git init --quiet --initial-branch=main "$repo"
git -C "$repo" fetch --quiet --depth=1 "$url" main
commit=$(git -C "$repo" rev-parse FETCH_HEAD)
printf '%s\n' "$commit" >"$run/commit"

if [ "$commit" = "$(cat "$state/deployed" 2>/dev/null)" ]; then
  echo "main is still $commit, already deployed"
  write_metrics 1 1
  exit 0
fi
echo "deploying $commit"
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
  docker compose --project-name tenant up --detach --build --remove-orphans --wait
docker image prune --force >/dev/null

printf '%s\n' "$commit" >"$state/deployed"
date +%s >"$state/last-success"
write_metrics 1 1
echo "deployed $commit"
