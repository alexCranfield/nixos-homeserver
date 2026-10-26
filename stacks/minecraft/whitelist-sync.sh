# minecraft-whitelist ENV_FILE CONTAINER: make the running server's whitelist
# the names on the WHITELIST line of ENV_FILE, through RCON (remote console),
# with no restart (#153). Added names can join at once; a removed name is
# kicked at once, since the server enforces its whitelist.
#
# Names are matched without regard to case, as Minecraft does. A name the
# server cannot add (misspelt, or Mojang's lookup down) is reported and the
# script fails, so the unit's failure posts to Discord; the other changes still
# go through. A server that is not running is left alone: its whitelist.json
# keeps the last list, and the unit runs again after the stack starts.
env_file=$1
container=$2

line=$(grep -E '^WHITELIST=' "$env_file" | tail -n 1) || {
  echo "no WHITELIST line in $env_file (the env key of secrets/minecraft.yaml)" >&2
  exit 1
}
value=${line#WHITELIST=}
value=${value//\"/}
value=${value//\'/}
want=()
IFS=',' read -ra items <<< "$value"
for item in "${items[@]}"; do
  item=${item//[[:space:]]/}
  if [ -n "$item" ]; then want+=("$item"); fi
done
# An empty list would lock everyone out; take it as a mistake.
if [ "${#want[@]}" -eq 0 ]; then
  echo "WHITELIST in $env_file names no one; leaving the server's whitelist alone" >&2
  exit 1
fi

health() { docker inspect -f '{{.State.Health.Status}}' "$container" 2> /dev/null; }
if ! state=$(health); then
  echo "$container is not running; its whitelist is synced when the stack next starts"
  exit 0
fi
# Running is not ready: RCON comes up only once the server has loaded.
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
rcon() { docker exec "$container" rcon-cli "$@" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g'; }
lower() { tr '[:upper:]' '[:lower:]'; }

# "There are 2 whitelisted player(s): A, B" or "There are no whitelisted players".
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
failed=0

for name in "${want[@]}"; do
  if ! grep -qxF "$(lower <<< "$name")" <<< "$have_lower"; then
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
  if ! grep -qxF "$(lower <<< "$name")" <<< "$want_lower"; then
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
