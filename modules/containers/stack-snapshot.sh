# stack-snapshot STACK [manual]
#
# Snapshots the data directory of a stack (modules/containers/stack-data.nix;
# the steps are in docs/superpowers/specs/2026-10-24-data-layout-design.md).
# With no second argument: a nightly snapshot named by its UTC time, then
# the nightly snapshots beyond the newest `keep` are deleted. With `manual`:
# a `manual-<time>` snapshot and no pruning. Both go in
# /.snapshots/stacks/STACK, beside <name>.config/, a copy of the stack's
# compose and override files. Exits non-zero on any failure.
#
# If the stack's containers run and it has hooks, the pre-command runs first;
# if it fails, no snapshot is taken. The post-command runs whenever the
# pre-command was started, even when the snapshot fails, so a server is never
# left with saving switched off. The whole run holds the stack's lock
# (/run/lock/stack-STACK.lock, also taken by the stack unit's up and by
# stack-rollback), waiting up to 15 minutes for it. (The stack unit's own wait
# is 10 minutes, so its 15 minute start timeout leaves time for `up --wait`.)
#
# The names, the stack-name check and the configuration copy are in
# stack-lib.sh, which stack-data.nix puts in front of this file.
log() {
  echo "stack-snapshot: $*"
}

# State of the run, global because the EXIT trap runs after main has returned.
# The post-command runs once, from the explicit call or from the trap.
pre="" post="" hooked=0 post_done=0

run_post() {
  [ "$hooked" = 1 ] && [ "$post_done" = 0 ] || return 0
  post_done=1
  [ -n "$post" ] || return 0
  log "running the post-snapshot command"
  "$post" || { echo "the post-snapshot command failed" >&2; return 1; }
}

finish() {
  local rc=$?
  run_post || [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}

main() {
  local stack=${1:?usage: stack-snapshot STACK [manual]} mode=${2:-nightly}
  check_stack_name "$stack"
  case $mode in
    nightly | manual) ;;
    *) echo "unknown mode: $mode" >&2; exit 2 ;;
  esac

  local settings=/etc/stacks/$stack/snapshot.json
  [ -r "$settings" ] || { echo "$stack has no $settings" >&2; exit 1; }
  local dir keep
  dir=$(jq -re .dataDir "$settings")
  keep=$(jq -re .keep "$settings")
  pre=$(jq -r '.pre // ""' "$settings")
  post=$(jq -r '.post // ""' "$settings")

  exec 9> "/run/lock/stack-$stack.lock"
  log "waiting for the lock of $stack"
  flock -w 900 9 || { echo "could not get the lock of $stack in 15 minutes" >&2; exit 1; }

  trap finish EXIT

  # A docker error must not read as "not running": that would snapshot a live
  # server without its hooks.
  local running
  running=$(docker compose -p "$stack" ps --status running -q) || {
    echo "could not ask docker whether $stack is running, no snapshot taken" >&2
    exit 1
  }
  if [ -n "$running" ]; then
    hooked=1
    if [ -n "$pre" ]; then
      log "running the pre-snapshot command"
      "$pre" || { echo "the pre-snapshot command failed, no snapshot taken" >&2; exit 1; }
    fi
  else
    log "$stack is not running, so no hooks"
  fi

  local name
  name=$(now)
  [ "$mode" = manual ] && name=manual-$name
  local snap=$root/$stack/$name
  log "snapshotting $dir to $snap"
  btrfs subvolume snapshot -r "$dir" "$snap"
  # A failing post-command still gets the configuration copy and the pruning,
  # so no half-made snapshot is left; the run fails at the end.
  local post_rc=0
  run_post || post_rc=1

  log "copying the configuration to $snap.config"
  copy_config "$stack" "$snap"

  if [ "$mode" = nightly ]; then
    local old
    mapfile -t old < <(snapshot_names "$stack")
    local excess=$((${#old[@]} - keep)) i
    for ((i = 0; i < excess; i++)); do
      log "deleting ${old[i]}"
      btrfs subvolume delete "$root/$stack/${old[i]}"
      rm -rf "$root/$stack/${old[i]}.config"
    done
  fi
  [ "$post_rc" -eq 0 ] || exit 1
  log "done: $name"
}

main "$@"
