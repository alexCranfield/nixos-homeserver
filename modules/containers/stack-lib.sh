# What stack-snapshot and stack-rollback share. stack-data.nix puts this text
# in front of each script, so there is one definition of the snapshot names,
# the stack-name check and the configuration copy. Nothing runs from here.
root=/.snapshots/stacks

# A UTC time that sorts by time: the end of every snapshot name.
time_re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z'

now() {
  date -u +%Y-%m-%dT%H%M%SZ
}

check_stack_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "bad stack name: $1" >&2; exit 2; }
}

# (`if`, not `[[ ]] && echo`: a last non-match would fail the pipeline.)
# snapshot_names STACK prints the nightly snapshot names, oldest first.
snapshot_names() {
  local f
  for f in "$root/$1"/*; do
    [ -d "$f" ] || continue
    f=${f##*/}
    if [[ $f =~ ^$time_re$ ]]; then echo "$f"; fi
  done | sort
}

# all_snapshot_names STACK prints every snapshot (nightly, manual-* and
# before-rollback-*, never a .config), oldest first by the time in the name.
all_snapshot_names() {
  local f
  for f in "$root/$1"/*; do
    [ -d "$f" ] || continue
    f=${f##*/}
    if [[ $f =~ ^(manual-|before-rollback-)?$time_re$ ]]; then echo "${f: -18} $f"; fi
  done | sort | cut -d' ' -f2
}

# copy_config STACK SNAPSHOT-PATH saves the stack's current compose and
# override files beside the snapshot, as SNAPSHOT-PATH.config.
copy_config() {
  mkdir -p "$2.config"
  cp -L "/etc/stacks/$1/compose.yml" "/etc/stacks/$1/override.yml" "$2.config/"
}
