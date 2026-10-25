# stack-watch PROJECT WEBHOOK_FILE ROLE_FILE COOLDOWN HOST ICON
#
# Posts each crash of a container in Compose project PROJECT to Discord
# (modules/containers/compose-stack.nix). Docker restarts the container
# itself; this only reports. Per container, with COOLDOWN as the window: a
# death that makes three or more in the window posts with the role, at most
# once per window; any other death posts without it if nothing was posted
# about the container in the window; the rest are only counted. So a crash
# loop of any speed posts at least once per window. The deaths are kept in
# the state file, the last post and the last ping in <file>.posted and
# <file>.pinged (tests/stack-watch.nix checks the cadences).
project=$1
webhook_file=$2
role_file=$3
cooldown=$4
host=$5
icon=$6

# `docker events` ends when Docker stops, as a deploy that changes Docker
# does. The watcher then waits for Docker to come back rather than exit: a
# unit that fails during a switch fails the whole deploy (#143). Deaths while
# Docker is down are not seen; with live-restore the containers keep running.
follow_events() {
  docker events --format '{{json .}}' --filter type=container --filter event=die \
    --filter "label=com.docker.compose.project=$project" |
    while read -r event; do
      # A stack stopping or restarting on purpose takes its containers down
      # too; only deaths while the stack is up are crashes.
      [ "$(systemctl is-active "stack-$project.service")" = active ] || continue
      name=$(jq -r '.Actor.Attributes.name' <<< "$event")
      code=$(jq -r '.Actor.Attributes.exitCode' <<< "$event")
      [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || continue
      state=$STATE_DIRECTORY/$name
      now=$(date +%s)
      # Deaths inside the window, one time per line; a damaged file counts as
      # none rather than silencing the container.
      recent=$( { cat "$state" 2>/dev/null || true; echo "$now"; } |
        awk -v now="$now" -v w="$cooldown" '/^[0-9]+$/ && now - $1 < w && now >= $1')
      printf '%s\n' "$recent" > "$state.new"
      mv "$state.new" "$state"
      count=$(wc -l <<< "$recent")
      # Whether the time in <file>.<what> is inside the window. A missing or
      # damaged file, or a time ahead of the clock, is not.
      within() {
        local t
        t=$(cat "$state.$1" 2>/dev/null || echo)
        [[ $t =~ ^[0-9]+$ ]] && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt "$cooldown" ]
      }
      if [ "$count" -ge 3 ] && ! within pinged; then
        title="$host: $name crashed (exit $code), $count times in $((cooldown / 60)) min" role=$role_file
        echo "$now" > "$state.pinged"
        echo "$now" > "$state.posted"
      elif ! within posted; then
        title="$host: $name crashed (exit $code)" role=-
        [ "$count" -eq 1 ] || title="$title, $count times in $((cooldown / 60)) min"
        echo "$now" > "$state.posted"
      else
        echo "$name died (exit $code), $count times in the window; not posted"
        continue
      fi
      echo "$title"
      journalctl "CONTAINER_NAME=$name" --lines 20 --no-pager --quiet --output short-iso |
        homeserver-notify "$webhook_file" "$role" "$icon" "$title" ||
        echo "could not post about $name" >&2
    done
}

while :; do
  # In the background, so `set -e` still holds inside it; only its ending is
  # tolerated.
  follow_events &
  wait $! || true
  echo "docker events ended; waiting for Docker" >&2
  sleep 1
  until docker info >/dev/null 2>&1; do sleep 2; done
done
