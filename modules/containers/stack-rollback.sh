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
    # A failing du must not end the listing: the size shows as ?.
    size=$(btrfs filesystem du -s "$root/$stack/$name" | awk 'NR == 2 { print $2 }') || size=
    printf '%-40s %10s' "$name" "${size:-?}"
    if differs "$stack" "$name"; then printf '  config differs'; fi
    printf '\n'
  done
}

# State for the failure message: `kept` is set once the current data is kept;
# `swapped` once $dir holds the chosen snapshot; `finished` at the end.
kept="" dir="" stack="" was_active=0 swapped=0 finished=0

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$kept" ] && [ "$finished" = 0 ]; then
    {
      echo "stack-rollback failed."
      if [ "$swapped" = 1 ]; then
        echo "$dir now holds the snapshot you chose, but the stack did not start."
      fi
      echo "Your data from before the rollback is in"
      echo "  $kept"
      echo "To put it back, with the stack stopped:"
      if [ "$swapped" = 1 ]; then
        echo "(first, as the failed start may have left containers running on the new data)"
        echo "  docker ps -aq --filter label=com.docker.compose.project=$stack | xargs -r docker rm -f"
      fi
      echo "(the first btrfs line only if $dir exists)"
      echo "  btrfs subvolume delete $dir"
      echo "  btrfs subvolume snapshot $kept $dir"
      if [ "$was_active" = 1 ]; then
        echo "Then: systemctl start stack-$stack"
      fi
    } >&2
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
  # Only a name in the listing: one line (grep reads newlines as several
  # patterns), not a path, not a .config.
  case $snap in
    *$'\n'*) echo "bad snapshot name" >&2; exit 1 ;;
  esac
  # (Not `grep -q` in a pipe: it can exit early and fail the pipeline.)
  all_snapshot_names "$stack" | grep -xF -- "$snap" > /dev/null || {
    echo "$stack has no snapshot $snap; run stack-rollback $stack to list them" >&2
    exit 1
  }
  local from=$root/$stack/$snap
  [ -d "$from" ] || { echo "$from is not a directory" >&2; exit 1; }

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

  # Something may have started the stack since the stop; never swap data
  # under running containers.
  local running
  running=$(docker ps -q --filter "label=com.docker.compose.project=$stack") || {
    echo "could not ask docker whether $stack is running, nothing was changed" >&2
    restart_if_active
    exit 1
  }
  if [ -n "$running" ]; then
    echo "$stack has running containers again after the stop, nothing was changed" >&2
    restart_if_active
    exit 1
  fi

  local before keep
  before=before-rollback-$(now)
  keep=$root/$stack/$before
  # Names have one-second resolution: never touch a snapshot of an earlier run.
  if [ -e "$keep" ] || [ -e "$keep.config" ]; then
    echo "$keep already exists (a rollback ran in this same second), nothing was changed" >&2
    restart_if_active
    exit 1
  fi
  if ! btrfs subvolume snapshot -r "$dir" "$keep"; then
    echo "could not keep the current data, nothing was changed" >&2
    restart_if_active
    exit 1
  fi
  if ! copy_config "$stack" "$keep"; then
    # Both paths are ours: they did not exist a moment ago, under the lock.
    btrfs subvolume delete "$keep" > /dev/null 2>&1 || true
    rm -rf "$keep.config"
    echo "could not keep the current data, nothing was changed" >&2
    restart_if_active
    exit 1
  fi
  kept=$keep

  btrfs subvolume delete "$dir"
  btrfs subvolume snapshot "$from" "$dir"
  chown "$uid:$gid" "$dir"
  chmod 0750 "$dir"
  swapped=1
  exec 9>&-

  if [ "$was_active" = 1 ]; then
    systemctl start "stack-$stack"
  else
    echo "stack-$stack was stopped, so it stays stopped"
  fi
  finished=1
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
