# stack-rollback STACK [SNAPSHOT] [--yes]
#
# With no snapshot: lists the stack's snapshots (nightly, manual-* and
# before-rollback-*, newest last) with the space only each one holds, and
# marks those whose saved configuration differs from the deployed one.
#
# With a snapshot: shows the plan and, when the configuration differs, the
# difference and a warning (the update that changed it is still deployed, so
# the old data would start under the new configuration; see the design in
# docs/superpowers/specs/2026-10-24-data-layout-design.md). After a
# confirmation (or --yes) it stops the stack, takes the lock, keeps the
# current data as before-rollback-<time>, replaces /srv/data/STACK with a
# writable copy of the snapshot, and starts the stack again only if it was
# running. The lock is released before any systemctl call that could wait on
# it. The names, the lock and the configuration copy are shared with
# stack-snapshot (stack-lib.sh, put in front of this file by stack-data.nix).

config_files=(compose.yml override.yml)

# differs STACK SNAPSHOT: true when the saved configuration is not the deployed one.
differs() {
  local f
  for f in "${config_files[@]}"; do
    cmp -s "$root/$1/$2.config/$f" "/etc/stacks/$1/$f" || return 0
  done
  return 1
}

list() {
  local stack=$1 name size
  local -a names
  mapfile -t names < <(all_snapshot_names "$stack")
  if [ "${#names[@]}" -eq 0 ]; then
    echo "$stack has no snapshots"
    return 0
  fi
  printf '%-40s %10s\n' "snapshot of $stack" "exclusive"
  for name in "${names[@]}"; do
    size=$(btrfs filesystem du -s "$root/$stack/$name" | awk 'NR == 2 { print $2 }')
    printf '%-40s %10s' "$name" "${size:-?}"
    if differs "$stack" "$name"; then printf '  config differs'; fi
    printf '\n'
  done
}

# State for the failure message: set once the current data is kept.
kept="" dir="" stack="" was_active=0 rollback_done=0

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$kept" ] && [ "$rollback_done" = 0 ]; then
    cat >&2 <<MSG
stack-rollback failed. Your data from before the rollback is in
  $kept
To put it back (the first line only if $dir exists), with the stack stopped:
  btrfs subvolume delete $dir
  btrfs subvolume snapshot $kept $dir
Then: systemctl start stack-$stack
MSG
  fi
  exit "$rc"
}

main() {
  local snap="" yes=0 arg
  for arg in "$@"; do
    case $arg in
      --yes) yes=1 ;;
      -*) echo "unknown option: $arg" >&2; exit 2 ;;
      *)
        if [ -z "$stack" ]; then stack=$arg
        elif [ -z "$snap" ]; then snap=$arg
        else echo "usage: stack-rollback STACK [SNAPSHOT] [--yes]" >&2; exit 2
        fi
        ;;
    esac
  done
  [ -n "$stack" ] || { echo "usage: stack-rollback STACK [SNAPSHOT] [--yes]" >&2; exit 2; }
  check_stack_name "$stack"

  local settings=/etc/stacks/$stack/snapshot.json
  [ -r "$settings" ] || { echo "$stack has no $settings" >&2; exit 1; }
  dir=$(jq -re .dataDir "$settings")
  local uid gid
  uid=$(jq -re .uid "$settings")
  gid=$(jq -re .gid "$settings")

  if [ -z "$snap" ]; then
    list "$stack"
    return 0
  fi
  # Only a name in the listing: not a path, not a .config.
  # (Not `grep -q` in a pipe: it can exit early and fail the pipeline.)
  all_snapshot_names "$stack" | grep -xF -- "$snap" > /dev/null || {
    echo "$stack has no snapshot $snap; run stack-rollback $stack to list them" >&2
    exit 1
  }
  local from=$root/$stack/$snap

  echo "Plan for $stack:"
  echo "  1. stop stack-$stack"
  echo "  2. keep the current data as before-rollback-<time> in $root/$stack"
  echo "  3. replace $dir with a writable copy of $snap"
  echo "  4. start stack-$stack again, if it is running now"
  if differs "$stack" "$snap"; then
    local f
    for f in "${config_files[@]}"; do
      cmp -s "$from.config/$f" "/etc/stacks/$stack/$f" && continue
      echo
      echo "$f differs (- the snapshot's, + deployed now):"
      diff -u "$from.config/$f" "/etc/stacks/$stack/$f" || true
    done
    echo
    echo "The update that changed this is still deployed: revert it and let comin deploy the revert before rolling back, or the old data starts under the new configuration."
    echo
  fi

  if [ "$yes" = 0 ]; then
    local answer=""
    printf 'Roll back %s to %s? [y/N] ' "$stack" "$snap"
    read -r answer || true
    case $answer in
      y | Y | yes) ;;
      *) echo; echo "not rolled back"; exit 1 ;;
    esac
  fi

  if systemctl is-active --quiet "stack-$stack"; then was_active=1; fi
  trap on_exit EXIT
  systemctl stop "stack-$stack"

  # No systemctl while the lock is held: a reload of the stack unit waits on it.
  exec 9> "/run/lock/stack-$stack.lock"
  flock -w 900 9 || { echo "could not get the lock of $stack in 15 minutes" >&2; restart_if_active; exit 1; }

  local before
  before=before-rollback-$(now)
  if ! { btrfs subvolume snapshot -r "$dir" "$root/$stack/$before" && copy_config "$stack" "$root/$stack/$before"; }; then
    echo "could not keep the current data, nothing was changed" >&2
    restart_if_active
    exit 1
  fi
  kept=$root/$stack/$before

  btrfs subvolume delete "$dir"
  btrfs subvolume snapshot "$from" "$dir"
  chown "$uid:$gid" "$dir"
  chmod 0750 "$dir"
  rollback_done=1
  exec 9>&-

  if [ "$was_active" = 1 ]; then
    systemctl start "stack-$stack"
  else
    echo "stack-$stack was stopped, so it stays stopped"
  fi
  echo "Rolled back $stack to $snap."
  echo "The data from before is kept in $kept (configuration in $kept.config)."
  echo "Once you are happy, delete it with:"
  echo "  btrfs subvolume delete $kept && rm -rf $kept.config"
}

# After a failure before anything changed: release the lock, then restart.
restart_if_active() {
  exec 9>&-
  if [ "$was_active" = 1 ]; then systemctl start "stack-$stack" || true; fi
}

main "$@"
