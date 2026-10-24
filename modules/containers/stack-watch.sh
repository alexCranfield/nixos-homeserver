# stack-watch PROJECT WEBHOOK_FILE ROLE_FILE COOLDOWN HOST ICON
#
# Posts each crash of a container in Compose project PROJECT to Discord
# (modules/containers/compose-stack.nix). Docker restarts the container
# itself; this only reports. Per container, within COOLDOWN seconds: the
# first death posts without the role, the third posts with it, and the rest
# are counted in the state file only.
project=$1
webhook_file=$2
role_file=$3
cooldown=$4
host=$5
icon=$6

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
    case $count in
      1) title="$host: $name crashed (exit $code)" role=- ;;
      3) title="$host: $name crashed (exit $code), 3 times in $((cooldown / 60)) min" role=$role_file ;;
      *) echo "$name died (exit $code), $count times in the window; not posted"; continue ;;
    esac
    echo "$title"
    journalctl "CONTAINER_NAME=$name" --lines 20 --no-pager --quiet --output short-iso |
      homeserver-notify "$webhook_file" "$role" "$icon" "$title" ||
      echo "could not post about $name" >&2
  done
