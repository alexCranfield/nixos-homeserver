# announce-comin REPO_URL: comin's build and deployment hooks for the public
# channel (#161). comin sets COMIN_PHASE, COMIN_STATUS, COMIN_ERROR_MSG,
# COMIN_GIT_SHA and COMIN_GIT_MSG. ANNOUNCE_GCROOT and ANNOUNCE_CURRENT come
# from the wrapper in announce.nix.
repo=$1

# The pull request, from the `(#N)` GitHub puts at the end of a squash merge's
# subject; otherwise the commit.
subject=${COMIN_GIT_MSG%%$'\n'*}
if [[ $subject =~ \(#([0-9]+)\)$ ]]; then
  link="$repo/pull/${BASH_REMATCH[1]}"
else
  link="$repo/commit/$COMIN_GIT_SHA"
fi

case $COMIN_PHASE/$COMIN_STATUS in
  build/built | "build/already built")
    [ -z "$COMIN_ERROR_MSG" ] || exit 0
    # comin runs this hook after the build and before it deploys, and points
    # this gcroot at what it built first. A build the host is already running
    # (a commit that changes only docs, or comin starting again) is not
    # deployed, so it is not announced.
    built=$(readlink "$ANNOUNCE_GCROOT") || exit 0
    if [ "$built" = "$(readlink "$ANNOUNCE_CURRENT")" ]; then
      exit 0
    fi
    exec homeserver-announce 🔵 "Applying update. Services on the nuc may restart briefly." "$link"
    ;;
  deploy/done)
    exec homeserver-announce 🟢 "Update complete." "$link"
    ;;
  deploy/failed)
    # The error goes to the private channel (notify.nix); here, only that it
    # failed.
    exec homeserver-announce --discord-only 🔴 "Update failed; the server is unchanged." "$link"
    ;;
esac
