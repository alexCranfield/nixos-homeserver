# Check for ticket 3.2 (#23): the crash watcher's counting
# (modules/containers/stack-watch.sh), without a VM (virtual machine).
#
# The script runs against stand-ins: `docker events` prints one container
# death per line of a list, `date` returns the next time from another list,
# and the notifier records who it would ping. Each case is a crash cadence and
# the posts it must produce: "-" for a quiet post, "role" for one that pings.
# tests/compose-stack.py covers the real Docker and notifier.
{ pkgs }:
let
  event = ''{"Actor":{"Attributes":{"name":"game-server-1","exitCode":"137"}}}'';

  stub = name: text: pkgs.writeShellScriptBin name text;
  stubs = [
    # `docker events` prints the deaths and ends, as when Docker stops; the
    # script then asks `docker info` whether Docker is back, and that ends it.
    (stub "docker" ''
      if [ "$1" = info ]; then kill -TERM "$PPID"; exit 1; fi
      for _ in $(seq "$(wc -l < "$TIMES")"); do echo '${event}'; done
    '')
    # The next time from $TIMES, one per call.
    (stub "date" ''
      n=$(( $(cat "$WORK/calls" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$WORK/calls"
      sed -n "''${n}p" "$TIMES"
    '')
    (stub "systemctl" "echo active")
    (stub "journalctl" "true")
    (stub "homeserver-notify" ''echo "$2" >> "$WORK/posts"; cat > /dev/null'')
  ];

  # cadence: seconds between crashes; count: how many; expected posts.
  cases = [
    # A crash loop: one quiet post, one ping, then nothing in the window.
    {
      name = "every 10 s";
      cadence = 10;
      count = 6;
      expected = "- role";
    }
    # Slow enough that the window always holds three deaths: one ping per
    # window, not one per crash.
    {
      name = "every 240 s";
      cadence = 240;
      count = 6;
      expected = "- role role";
    }
    # Two deaths in every window, never three: a quiet post once per window,
    # never silence.
    {
      name = "every 300 s";
      cadence = 300;
      count = 12;
      expected = "- - - - - -";
    }
    {
      name = "every 450 s";
      cadence = 450;
      count = 8;
      expected = "- - - -";
    }
    # Far apart: each crash is the first in its window.
    {
      name = "every 700 s";
      cadence = 700;
      count = 3;
      expected = "- - -";
    }
  ];
in
pkgs.runCommand "stack-watch"
  {
    nativeBuildInputs = stubs ++ [
      pkgs.gawk
      pkgs.jq
    ];
  }
  (
    pkgs.lib.concatMapStrings (c: ''
      export WORK=$(mktemp -d) STATE_DIRECTORY=$(mktemp -d)
      export TIMES=$WORK/times
      for i in $(seq 0 ${toString (c.count - 1)}); do echo $((1000000 + i * ${toString c.cadence})); done > "$TIMES"
      # 143: stopped by the `docker info` stub, waiting for Docker (#143).
      status=0
      bash -euo pipefail ${../modules/containers/stack-watch.sh} game webhook role 600 nuc icon > /dev/null || status=$?
      [ "$status" -eq 143 ] || { echo "${c.name}: exit $status, not 143" >&2; exit 1; }
      posts=$(tr '\n' ' ' < "$WORK/posts" | sed 's/ $//')
      echo "${c.name}: $posts"
      [ "$posts" = "${c.expected}" ] || { echo "${c.name}: expected ${c.expected}" >&2; exit 1; }
    '') cases
    + "touch $out\n"
  )
