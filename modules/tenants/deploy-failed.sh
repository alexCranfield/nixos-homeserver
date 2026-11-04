# tenant-deploy-failed.service, tenant-deploy's OnFailure (./runner.nix):
# tells the tenant that their commit failed to deploy, by posting the run's
# log tail to their FAILURE_WEBHOOK, once per commit and stage.
#
# A failure while fetching or decrypting is the platform's, not the tenant's
# (a deploy key not yet added, GitHub down, prod.yaml not encrypted to the
# runner's key): nothing is posted here, and Alex's TenantDeployFailing alert
# reads the metric deploy.sh wrote instead.
state=/var/lib/tenant-runner
run=/run/tenant-runner

stage=$(cat "$run/stage" 2>/dev/null || echo unknown)
commit=$(cat "$run/commit" 2>/dev/null || true)
case $stage in
  compose) ;;
  done)
    # The last run succeeded, so this one failed before the script ran (its
    # credential, its keys): the platform's.
    echo "the unit failed before the deploy ran, a platform fault: not posted to the tenant"
    exit 0
    ;;
  *)
    echo "the deploy failed at the $stage stage, a platform fault: not posted to the tenant"
    exit 0
    ;;
esac

key="$commit $stage"
if [ "$(cat "$state/notified" 2>/dev/null)" = "$key" ]; then
  echo "already posted for $commit"
  exit 0
fi
if [ ! -s "$run/webhook" ]; then
  echo "no FAILURE_WEBHOOK in secrets/prod.yaml: nowhere to post"
  exit 0
fi

id=$(systemctl show --property=InvocationID --value tenant-deploy.service)
tail=$(journalctl --output=cat --lines=30 --no-pager "_SYSTEMD_INVOCATION_ID=$id" | tail -c 1500)
# The backticks are Markdown's, for the webhook.
# shellcheck disable=SC2016
message=$(printf 'tenant-run: deploying %s failed.\n```\n%s\n```' "${commit:0:12}" "$tail")
# Discord reads `content`, Slack `text`; both are sent.
jq -n --arg m "$message" '{content: $m, text: $m}' |
  curl --fail --silent --show-error --max-time 20 \
    --header 'Content-Type: application/json' --data @- "$(cat "$run/webhook")"
printf '%s\n' "$key" >"$state/notified"
echo "posted the failure of $commit"
