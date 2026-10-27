# minecraft-whitelist ENV_FILE CONTAINER: make the running server's whitelist
# the names on the WHITELIST line of ENV_FILE, through RCON (remote console),
# with no restart (#153). Added names can join at once; a removed name is
# kicked at once, since the server enforces its whitelist.
#
# Names are matched without regard to case, as Minecraft does. A name that is
# not a valid player name, or that the server cannot add (misspelt, or Mojang's
# lookup down), is reported and the script fails, so the unit's failure posts
# to Discord; the other names are still applied. So does a server that is not
# healthy within five minutes; its whitelist.json keeps the last list.
env_file=$1
container=$2

line=$(grep -E '^WHITELIST=' "$env_file" | tail -n 1) || {
  echo "no WHITELIST line in $env_file (the env key of secrets/minecraft.yaml)" >&2
  exit 1
}
value=${line#WHITELIST=}
value=${value//\"/}
value=${value//\'/}
lower() { tr '[:upper:]' '[:lower:]'; }
failed=0
want=()
seen=
IFS=',' read -ra items <<< "$value"
for item in "${items[@]}"; do
  item=${item//[[:space:]]/}
  if [ -z "$item" ]; then continue; fi
  # Minecraft names: 3 to 16 letters, digits and underscores. Checking also
  # keeps anything starting with `-` away from grep and rcon-cli.
  if ! [[ $item =~ ^[A-Za-z0-9_]{3,16}$ ]]; then
    echo "not a valid player name, skipped: $item" >&2
    failed=1
    continue
  fi
  # The same name twice, in any case, is added once.
  if grep -qxF -e "$(lower <<< "$item")" <<< "$seen"; then continue; fi
  seen+=$(lower <<< "$item")$'\n'
  want+=("$item")
done
# An empty list would lock everyone out; take it as a mistake.
if [ "${#want[@]}" -eq 0 ]; then
  echo "WHITELIST in $env_file names no one; leaving the server's whitelist alone" >&2
  exit 1
fi

# The unit runs only while the stack is active, so a container that is
# missing or stopped is being recreated (a reload) or has gone wrong: wait for
# it either way, and fail if it does not come back. A stopped container can
# keep its last health status, so check it runs too. Running is not ready
# either: RCON comes up only once the server has loaded.
health() {
  docker inspect -f '{{if .State.Running}}{{.State.Health.Status}}{{else}}stopped{{end}}' "$container" 2> /dev/null
}
state=$(health) || state=gone
for _ in $(seq 60); do
  [ "$state" = healthy ] && break
  sleep 5
  state=$(health) || state=gone
done
if [ "$state" != healthy ]; then
  echo "$container did not become healthy (last: $state)" >&2
  exit 1
fi

# rcon-cli ends its replies with a colour reset; drop escape codes and CRs.
# A failed `docker exec` (the container going away mid-run) ends the script
# there, under `set -e`; the unit fails and the next run picks up.
rcon() { docker exec "$container" rcon-cli "$@" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g'; }

# "There are 2 whitelisted player(s): A, B" or "There are no whitelisted players".
# RCON cuts replies at 4096 bytes, about 200 names; a list that long would
# fail here, not remove anyone.
reply=$(rcon whitelist list)
have=()
case $reply in
  *"whitelisted player(s): "*)
    IFS=',' read -ra items <<< "${reply#*: }"
    for item in "${items[@]}"; do
      item=${item//[[:space:]]/}
      if [ -n "$item" ]; then have+=("$item"); fi
    done
    ;;
  *"no whitelisted players"*) ;;
  *)
    echo "unexpected reply to whitelist list: $reply" >&2
    exit 1
    ;;
esac

want_lower=$(printf '%s\n' "${want[@]}" | lower)
have_lower=$(printf '%s\n' "${have[@]}" | lower)

for name in "${want[@]}"; do
  if ! grep -qxF -e "$(lower <<< "$name")" <<< "$have_lower"; then
    reply=$(rcon whitelist add "$name")
    case $reply in
      "Added "*" to the whitelist"*) echo "added $name" ;;
      *)
        echo "could not add $name: $reply" >&2
        failed=1
        ;;
    esac
  fi
done

for name in "${have[@]}"; do
  if ! grep -qxF -e "$(lower <<< "$name")" <<< "$want_lower"; then
    reply=$(rcon whitelist remove "$name")
    case $reply in
      "Removed "*" from the whitelist"*) echo "removed $name" ;;
      *)
        echo "could not remove $name: $reply" >&2
        failed=1
        ;;
    esac
  fi
done

echo "whitelist: $(rcon whitelist list)"
exit "$failed"
