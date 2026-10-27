# homeserver-announce [--game-only|--discord-only] ICON TEXT [LINK]: a public
# status message (#161), to the public Discord webhook and into each running
# Minecraft server's chat. The webhook file and the containers come from the
# environment the wrapper in announce.nix sets.
#
# A server that is not running is skipped, without error: nobody is there to
# read it. A Discord post that fails makes the exit status 1, after the game
# has had its message; callers that must not fail ignore it.
where=both
case ${1:-} in
  --game-only)
    where=game
    shift
    ;;
  --discord-only)
    where=discord
    shift
    ;;
esac
icon=$1
text=$2
link=${3:-}
status=0

if [ "$where" != discord ] && [ -n "$ANNOUNCE_CONTAINERS" ]; then
  # tellraw takes JSON (JavaScript Object Notation) text components; jq makes
  # it, so quotes and backslashes in the text stay text. The link is a
  # clickable "More info".
  json=$(jq -cn --arg text "$text" --arg link "$link" '
    ["", {text: "[nuc] ", color: "gold"}, {text: $text}]
    + if $link == "" then [] else
        [{text: " More info", color: "aqua", underlined: true,
          clickEvent: {action: "open_url", value: $link}}]
      end')
  read -ra containers <<< "$ANNOUNCE_CONTAINERS"
  for c in "${containers[@]}"; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2> /dev/null)" = true ]; then
      # RCON (remote console) answers only once the server has loaded; a
      # server still starting refuses, and that is logged, not fatal. rcon-cli
      # exits 0 even when the server rejects the command, so its reply is
      # checked too: empty, or "No player was found" with nobody on.
      if reply=$(timeout 20 docker exec "$c" rcon-cli tellraw @a "$json"); then
        reply=$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g' <<< "$reply")
        case $reply in
          "" | "No player was found") ;;
          *) echo "$c did not show the message: $reply" >&2 ;;
        esac
      else
        echo "could not show the message in $c" >&2
      fi
    fi
  done
fi

if [ "$where" != game ]; then
  title=$text
  if [ -n "$link" ]; then
    # Angle brackets: Discord shows the link without a preview card.
    title="$text More info: <$link>"
  fi
  homeserver-notify "$ANNOUNCE_WEBHOOK" - "$icon" "$title" < /dev/null || {
    echo "could not post to the public channel" >&2
    status=1
  }
fi
exit "$status"
