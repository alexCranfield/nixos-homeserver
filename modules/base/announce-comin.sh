# announce-comin REPO_URL: comin's build and deployment hooks for the public
# channel (#161). comin sets COMIN_PHASE, COMIN_STATUS, COMIN_ERROR_MSG,
# COMIN_GENERATION, COMIN_GIT_SHA and COMIN_GIT_MSG. ANNOUNCE_GCROOT,
# ANNOUNCE_CURRENT and ANNOUNCE_STATE come from the wrapper in announce.nix.
repo=$1

# The pull request, from the `(#N)` GitHub puts at the end of a squash merge's
# subject; otherwise the commit.
subject=${COMIN_GIT_MSG%%$'\n'*}
if [[ $subject =~ \(#([0-9]+)\)$ ]]; then
  link="$repo/pull/${BASH_REMATCH[1]}"
else
  link="$repo/commit/$COMIN_GIT_SHA"
fi

# The two hooks are paired by a marker per announced build, so an outcome is
# posted only for an update that was announced. comin's own idea of what is
# already deployed compares with the deployment before last (deployer.go,
# IsAlreadyDeployed, 0.14.0), so after a real update it switches again to the
# same system for a merge that changes only docs: that switch changes
# nothing, and posts nothing. The markers are in /run, so a reboot clears them.
marker=$ANNOUNCE_STATE/${COMIN_GENERATION//\//_}

case $COMIN_PHASE/$COMIN_STATUS in
  build/built | "build/already built")
    [ -z "$COMIN_ERROR_MSG" ] || exit 0
    # comin runs this hook after the build and before it deploys, and points
    # this gcroot at what it built first. The system already running needs
    # no announcement, whatever comin then does with it.
    built=$(readlink "$ANNOUNCE_GCROOT") || exit 0
    if [ "$built" = "$(readlink "$ANNOUNCE_CURRENT")" ]; then
      exit 0
    fi
    mkdir -p "$ANNOUNCE_STATE"
    touch "$marker"
    exec homeserver-announce 🔵 "Applying update. Services on the nuc may restart briefly." "$link"
    ;;
  "deploy/done" | "deploy/failed")
    [ -e "$marker" ] || exit 0
    # Its own only: the next merge's may be there already. A marker whose
    # build a newer merge replaced before it deployed stays until a reboot,
    # unused.
    rm -f "$marker"
    if [ "$COMIN_STATUS" = "done" ]; then
      exec homeserver-announce 🟢 "Update complete." "$link"
    fi
    # The error goes to the private channel (notify.nix); here, only that it
    # failed.
    exec homeserver-announce --discord-only 🔴 "Update failed; the server is unchanged." "$link"
    ;;
esac
